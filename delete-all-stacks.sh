#!/bin/bash

# ============================================================
# delete-all-stacks.sh
# - Logs to ./delete-logs
# - Verifies AWS identity
# - Lets you pick stacks to delete
# - Figures out dependency order (imports first, exporters last)
# - Handles termination protection
# - Uses AWS waiters for reliable progress
# - Optional sweep of orphaned resources (same as before)
# ============================================================

set -u

# === CREATE LOG FOLDER AND FILE ===
LOG_DIR="./delete-logs"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="$LOG_DIR/delete-log-$TIMESTAMP.txt"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "📜 Logging to $LOG_FILE"

# === AWS ACCOUNT SAFETY CHECK ===
echo "🔒 Checking AWS identity..."

if ! account_id=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null); then
  echo "❌ Could not get AWS identity. Are your credentials configured?"
  exit 1
fi
user_arn=$(aws sts get-caller-identity --query "Arn" --output text)
caller_user=$(echo "$user_arn" | sed 's/^.*\///')
region=$(aws configure get region)
region=${region:-"us-east-1"}

echo "🚨 You are logged in as:"
echo "👤 User:       $caller_user"
echo "🔗 ARN:        $user_arn"
echo "🏢 Account ID: $account_id"
echo "🌍 Region:     $region"
echo ""

read -p "❓ Is this the right account to wreak havoc on? (y/N): " confirm_account
if [[ "${confirm_account:-N}" != [yY] ]]; then
  echo "🛑 Good call. Destruction postponed."
  exit 1
fi

# === LIST STACKS ===
echo "🕵️ Scanning for active CloudFormation stacks..."

# Include common deletable terminal states
if ! all_stacks=$(aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
  --query "StackSummaries[*].StackName" --output text 2>/dev/null); then
  echo "❌ Failed to list stacks. Check your permissions."
  exit 1
fi

if [ -z "${all_stacks}" ]; then
  echo "🎉 No active stacks found. You're already zen."
  exit 0
fi

echo "🧨 Here are your active stacks:"
i=1
declare -a stack_options
for stack in $all_stacks; do
  echo " [$i] 💣 $stack"
  stack_options[$i]=$stack
  ((i++))
done

echo ""
read -rp "🔢 Enter the numbers of the stacks you want to delete (e.g., 1 3 4), or press Enter to cancel: " selection

declare -a selected_stacks
for num in $selection; do
  if [[ "$num" =~ ^[0-9]+$ ]] && [[ -n "${stack_options[$num]:-}" ]]; then
    selected_stacks+=("${stack_options[$num]}")
  else
    echo "⚠️ Invalid selection: '$num'. Skipping."
  fi
done

if [ "${#selected_stacks[@]}" -eq 0 ]; then
  echo "❌ No valid stacks selected. Aborting deletion."
  exit 1
fi

echo "⚠️ You selected the following stacks for deletion:"
for s in "${selected_stacks[@]}"; do
  echo "   💥 $s"
done
echo ""

read -p "🚨 Final confirmation — delete these stacks? (y/N): " confirm_delete
if [[ "${confirm_delete:-N}" != [yY] ]]; then
  echo "🙅‍♂️ Operation cancelled. Infrastructure spared."
  exit 1
fi

# === UTILS ===
contains_name() {
  local needle="$1"
  shift
  for x in "$@"; do
    [[ "$x" == "$needle" ]] && return 0
  done
  return 1
}

# === MAP SELECTED STACK NAMES <-> IDS ===
declare -A id_by_name
declare -A name_by_id
echo "🧭 Resolving StackIds for selected stacks..."
for s in "${selected_stacks[@]}"; do
  sid=$(aws cloudformation describe-stacks --stack-name "$s" --query "Stacks[0].StackId" --output text 2>/dev/null)
  if [ -z "$sid" ] || [[ "$sid" == "None" ]]; then
    echo "❌ Could not resolve StackId for $s. Skipping."
    continue
  fi
  id_by_name["$s"]="$sid"
  name_by_id["$sid"]="$s"
done

# If any selected stack failed to resolve, drop it
filtered=()
for s in "${selected_stacks[@]}"; do
  if [ -n "${id_by_name[$s]:-}" ]; then
    filtered+=("$s")
  fi
done
selected_stacks=("${filtered[@]}")

if [ "${#selected_stacks[@]}" -eq 0 ]; then
  echo "❌ No resolvable stacks remain. Aborting."
  exit 1
fi

# === BUILD DEPENDENCY GRAPH (importers depend on exporters) ===
# deps_incoming[importer_name]="exporter_name exporter_name ..."
declare -A deps_incoming

echo "🧠 Analyzing stack dependencies (Exports/Imports)..."

# Build a set of selected IDs for quick membership checks
declare -A selected_id_set
for s in "${selected_stacks[@]}"; do
  selected_id_set["${id_by_name[$s]}"]=1
done

# Collect all exports in the account (no jq/python needed)
# We'll output as lines: "<ExportingStackId>|<ExportName>"
tmp_exports_file="$(mktemp)"
if ! aws cloudformation list-exports --query "Exports[].{Id:ExportingStackId,Name:Name}" --output text > "$tmp_exports_file" 2>/dev/null; then
  echo "⚠️ Could not list exports. Proceeding without dependency ordering."
fi

# Read each export line: "<Id>\t<Name>"
if [ -s "$tmp_exports_file" ]; then
  while IFS=$'\t' read -r exp_id exp_name; do
    # Only consider exports whose exporter is among the selected stacks
    if [ -n "${selected_id_set[$exp_id]:-}" ]; then
      # For each export name, list importers (StackIds)
      importers=$(aws cloudformation list-imports --export-name "$exp_name" --query "Imports" --output text 2>/dev/null || true)
      if [ -n "$importers" ]; then
        for importer_id in $importers; do
          importer_name="${name_by_id[$importer_id]:-}"
          exporter_name="${name_by_id[$exp_id]:-}"
          # Only add edge if BOTH importer and exporter are among our selected names
          if [ -n "$importer_name" ] && [ -n "$exporter_name" ]; then
            # importer depends on exporter
            current="${deps_incoming[$importer_name]:-}"
            # avoid duplicate word
            if [[ " $current " != *" $exporter_name "* ]]; then
              deps_incoming["$importer_name"]="${current:+$current }$exporter_name"
            fi
          fi
        done
      fi
    fi
  done < "$tmp_exports_file"
fi
rm -f "$tmp_exports_file"

# === TOPOLOGICAL ORDER (importers first, exporters last) ===
ordered=()
pending=("${selected_stacks[@]}")

while [ "${#pending[@]}" -gt 0 ]; do
  progressed=false
  next_pending=()
  for s in "${pending[@]}"; do
    # s can be deleted now if it has no incoming deps
    if [ -z "${deps_incoming[$s]:-}" ]; then
      ordered+=("$s")
      progressed=true
      # remove s from all other incoming lists
      for k in "${!deps_incoming[@]}"; do
        # remove whole-word matches
        deps_incoming[$k]=$(echo " ${deps_incoming[$k]} " | sed "s/ $s / /g" | xargs || true)
        # normalize empty
        if [[ "${deps_incoming[$k]}" == "" ]]; then
          unset 'deps_incoming[$k]'
        fi
      done
    else
      next_pending+=("$s")
    fi
  done
  if ! $progressed; then
    # Likely a cycle via external (non-selected) exports/imports.
    # Append remaining to avoid infinite loop (best-effort deletion).
    ordered+=("${next_pending[@]}")
    break
  fi
  pending=("${next_pending[@]}")
done

echo "🗺️ Deletion order (importers → exporters):"
for s in "${ordered[@]}"; do
  echo "   💥 $s"
done

echo "⏳ Initiating deletions in the computed order..."

# === DELETE WITH TERMINATION PROTECTION HANDLING + RELIABLE WAIT ===
for stack in "${ordered[@]}"; do
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🛡️ Checking termination protection for: $stack ..."
  tp=$(aws cloudformation describe-stacks --stack-name "$stack" --query "Stacks[0].EnableTerminationProtection" --output text 2>/dev/null || echo "False")
  if [ "$tp" == "True" ]; then
    read -p "⚠️  Termination protection is ON for $stack. Disable and proceed? (y/N): " ans
    if [[ "${ans:-N}" =~ ^[yY]$ ]]; then
      if aws cloudformation update-termination-protection --stack-name "$stack" --no-enable-termination-protection; then
        echo "🛡️ Termination protection disabled."
      else
        echo "❌ Failed to disable termination protection on $stack. Skipping."
        continue
      fi
    else
      echo "⏭️ Skipping $stack due to termination protection."
      continue
    fi
  fi

  echo "🗑️ Initiating deletion of stack: $stack ..."
  if ! aws cloudformation delete-stack --stack-name "$stack"; then
    echo "❌ Delete API call failed immediately for $stack. Check IAM or stack state."
    continue
  fi

  echo "🔎 Verifying deletion started..."
  attempts=0
  started=false
  while [ $attempts -lt 6 ]; do
    status=$(aws cloudformation describe-stacks --stack-name "$stack" --query "Stacks[0].StackStatus" --output text 2>/dev/null || true)
    if [[ "$status" == "DELETE_IN_PROGRESS" ]]; then
      started=true
      echo "🏃 Deletion in progress for $stack."
      break
    elif [[ "$status" == "DELETE_COMPLETE" ]]; then
      started=true
      echo "✅ $stack already deleted."
      break
    elif [[ -z "$status" || "$status" == "None" ]]; then
      started=true
      echo "✅ $stack no longer exists."
      break
    else
      echo "⌛ Not yet started (status: ${status}). Waiting a bit..."
      sleep 5
    fi
    attempts=$((attempts+1))
  done

  if ! $started; then
    echo "🛑 Deletion for $stack never transitioned to DELETE_IN_PROGRESS."
    echo "   ➤ Re-check termination protection and imports/exports."
    continue
  fi

  echo "⏳ Waiting for $stack to be deleted (this can take a while)..."
  if aws cloudformation wait stack-delete-complete --stack-name "$stack"; then
    echo "✅ Stack $stack deleted."
  else
    # Surface final status and first DELETE_FAILED reason if available
    st=$(aws cloudformation describe-stacks --stack-name "$stack" --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "unknown")
    reason=$(aws cloudformation describe-stack-events --stack-name "$stack" \
      --query "StackEvents[?ResourceStatus=='DELETE_FAILED']|[0].ResourceStatusReason" --output text 2>/dev/null || true)
    echo "❌ Deletion did not complete for $stack. Status: $st"
    [ -n "$reason" ] && [ "$reason" != "None" ] && echo "   Reason: $reason"
  fi
done

# === CLEANUP OF ORPHANED RESOURCES ===
echo ""
echo "🧹 Now sweeping for sneaky resources that love to charge silently..."

nat_ids=$(aws ec2 describe-nat-gateways --query "NatGateways[*].NatGatewayId" --output text 2>/dev/null || true)
if [ -n "$nat_ids" ]; then
  for nat in $nat_ids; do
    echo "🚪 Deleting NAT Gateway: $nat (it's not free, my friend)"
    aws ec2 delete-nat-gateway --nat-gateway-id "$nat" || echo "⚠️ Could not delete NAT Gateway $nat"
  done
else
  echo "✅ No NAT Gateways detected. No hidden toll booths."
fi

eips=$(aws ec2 describe-addresses --query "Addresses[*].AllocationId" --output text 2>/dev/null || true)
if [ -n "$eips" ]; then
  for eip in $eips; do
    echo "📡 Releasing Elastic IP: $eip — it shall float freely."
    aws ec2 release-address --allocation-id "$eip" || echo "⚠️ Could not release EIP $eip"
  done
else
  echo "✅ No Elastic IPs haunting your bill."
fi

volumes=$(aws ec2 describe-volumes --filters Name=status,Values=available \
  --query "Volumes[*].VolumeId" --output text 2>/dev/null || true)
if [ -n "$volumes" ]; then
  for vol in $volumes; do
    echo "💽 Deleting unattached EBS volume: $vol — it's just sitting there!"
    aws ec2 delete-volume --volume-id "$vol" || echo "⚠️ Could not delete volume $vol"
  done
else
  echo "✅ No EBS volumes eating space (and money)."
fi

snapshots=$(aws ec2 describe-snapshots --owner-ids self \
  --query "Snapshots[*].SnapshotId" --output text 2>/dev/null || true)
if [ -n "$snapshots" ]; then
  for snap in $snapshots; do
    echo "📸 Deleting snapshot: $snap — because memories fade."
    aws ec2 delete-snapshot --snapshot-id "$snap" || echo "⚠️ Could not delete snapshot $snap"
  done
else
  echo "✅ No snapshots found. No nostalgia to pay for."
fi

lbs=$(aws elbv2 describe-load-balancers --query "LoadBalancers[*].LoadBalancerArn" --output text 2>/dev/null || true)
if [ -n "$lbs" ]; then
  for lb in $lbs; do
    echo "⚖️ Deleting load balancer: $lb — it’s just balancing nothing now."
    aws elbv2 delete-load-balancer --load-balancer-arn "$lb" || echo "⚠️ Could not delete load balancer $lb"
  done
else
  echo "✅ No load balancers detected. It's chaos, but cheap."
fi

echo "🎯 Cleanup complete. Your AWS account is now squeaky clean and budget-friendly!"



# #!/bin/bash

# # === CREATE LOG FOLDER AND FILE ===
# LOG_DIR="./delete-logs"
# TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
# LOG_FILE="$LOG_DIR/delete-log-$TIMESTAMP.txt"

# mkdir -p "$LOG_DIR"
# exec > >(tee -a "$LOG_FILE") 2>&1

# echo "📜 Logging to $LOG_FILE"

# # === AWS ACCOUNT SAFETY CHECK ===
# echo "🔒 Checking AWS identity..."

# account_id=$(aws sts get-caller-identity --query "Account" --output text)
# user_arn=$(aws sts get-caller-identity --query "Arn" --output text)
# caller_user=$(echo "$user_arn" | sed 's/^.*\///')
# region=$(aws configure get region)

# echo "🚨 You are logged in as:"
# echo "👤 User:       $caller_user"
# echo "🔗 ARN:        $user_arn"
# echo "🏢 Account ID: $account_id"
# echo "🌍 Region:     $region"
# echo ""

# read -p "❓ Is this the right account to wreak havoc on? (y/N): " confirm_account
# if [[ "$confirm_account" != "y" && "$confirm_account" != "Y" ]]; then
#   echo "🛑 Good call. Destruction postponed."
#   exit 1
# fi

# # === LIST STACKS ===
# echo "🕵️ Scanning for active CloudFormation stacks..."

# all_stacks=$(aws cloudformation list-stacks \
#   --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
#   --query "StackSummaries[*].StackName" --output text)

# if [ -z "$all_stacks" ]; then
#   echo "🎉 No active stacks found. You're already zen."
# else
#   echo "🧨 Here are your active stacks:"
#   i=1
#   declare -a stack_options
#   for stack in $all_stacks; do
#     echo " [$i] 💣 $stack"
#     stack_options[$i]=$stack
#     ((i++))
#   done

#   echo ""
#   read -p "🔢 Enter the numbers of the stacks you want to delete (e.g., 1 3 4), or press Enter to cancel: " selection

#   declare -a selected_stacks
#   for num in $selection; do
#     if [[ "$num" =~ ^[0-9]+$ ]] && [[ -n "${stack_options[$num]}" ]]; then
#       selected_stacks+=("${stack_options[$num]}")
#     else
#       echo "⚠️ Invalid selection: '$num'. Skipping."
#     fi
#   done

#   if [ "${#selected_stacks[@]}" -eq 0 ]; then
#     echo "❌ No valid stacks selected. Aborting deletion."
#     exit 1
#   fi

#   echo "⚠️ You selected the following stacks for deletion:"
#   for s in "${selected_stacks[@]}"; do
#     echo "   💥 $s"
#   done
#   echo ""

#   read -p "🚨 Final confirmation — delete these stacks? (y/N): " confirm_delete
#   if [[ "$confirm_delete" != "y" && "$confirm_delete" != "Y" ]]; then
#     echo "🙅‍♂️ Operation cancelled. Infrastructure spared."
#     exit 1
#   fi

#   for stack in "${selected_stacks[@]}"; do
#     echo "🗑️ Initiating deletion of stack: $stack ..."
#     aws cloudformation delete-stack --stack-name "$stack"
#   done

#   echo "⏳ Watching the destruction unfold..."
#   for stack in "${selected_stacks[@]}"; do
#     echo "⏳ Waiting for stack: $stack to be deleted (max 5 minutes)..."
#     for ((i=1; i<=20; i++)); do
#       status=$(aws cloudformation describe-stacks \
#         --stack-name "$stack" \
#         --query "Stacks[0].StackStatus" \
#         --output text 2>/dev/null)

#       if [[ "$status" == "DELETE_COMPLETE" ]]; then
#         echo "✅ Stack $stack is gone. Oblivion achieved."
#         break
#       elif [[ "$status" == "DELETE_FAILED" ]]; then
#         echo "❌ Deletion failed for $stack. Something resisted. Maybe it's Skynet."
#         break
#       elif [[ "$status" == "" ]]; then
#         echo "✅ Stack $stack no longer exists. Mission accomplished!"
#         break
#       else
#         echo "⌛ Still deleting ($i/20)... status: $status"
#         sleep 15
#       fi
#     done

#     # Retry deletion just in case it was skipped earlier due to dependency
#     echo "🔁 Double-checking $stack still exists..."
#     aws cloudformation describe-stacks --stack-name "$stack" &>/dev/null
#     if [ $? -eq 0 ]; then
#       echo "🔁 Retrying deletion of stubborn stack: $stack ..."
#       aws cloudformation delete-stack --stack-name "$stack"
#     fi
#   done
# fi

# # === CLEANUP OF ORPHANED RESOURCES ===
# echo "🧹 Now sweeping for sneaky resources that love to charge silently..."

# nat_ids=$(aws ec2 describe-nat-gateways --query "NatGateways[*].NatGatewayId" --output text)
# if [ -n "$nat_ids" ]; then
#   for nat in $nat_ids; do
#     echo "🚪 Deleting NAT Gateway: $nat (it's not free, my friend)"
#     aws ec2 delete-nat-gateway --nat-gateway-id "$nat"
#   done
# else
#   echo "✅ No NAT Gateways detected. No hidden toll booths."
# fi

# eips=$(aws ec2 describe-addresses --query "Addresses[*].AllocationId" --output text)
# if [ -n "$eips" ]; then
#   for eip in $eips; do
#     echo "📡 Releasing Elastic IP: $eip — it shall float freely."
#     aws ec2 release-address --allocation-id "$eip"
#   done
# else
#   echo "✅ No Elastic IPs haunting your bill."
# fi

# volumes=$(aws ec2 describe-volumes --filters Name=status,Values=available \
#   --query "Volumes[*].VolumeId" --output text)
# if [ -n "$volumes" ]; then
#   for vol in $volumes; do
#     echo "💽 Deleting unattached EBS volume: $vol — it's just sitting there!"
#     aws ec2 delete-volume --volume-id "$vol"
#   done
# else
#   echo "✅ No EBS volumes eating space (and money)."
# fi

# snapshots=$(aws ec2 describe-snapshots --owner-ids self \
#   --query "Snapshots[*].SnapshotId" --output text)
# if [ -n "$snapshots" ]; then
#   for snap in $snapshots; do
#     echo "📸 Deleting snapshot: $snap — because memories fade."
#     aws ec2 delete-snapshot --snapshot-id "$snap"
#   done
# else
#   echo "✅ No snapshots found. No nostalgia to pay for."
# fi

# lbs=$(aws elbv2 describe-load-balancers --query "LoadBalancers[*].LoadBalancerArn" --output text)
# if [ -n "$lbs" ]; then
#   for lb in $lbs; do
#     echo "⚖️ Deleting load balancer: $lb — it’s just balancing nothing now."
#     aws elbv2 delete-load-balancer --load-balancer-arn "$lb"
#   done
# else
#   echo "✅ No load balancers detected. It's chaos, but cheap."
# fi

# echo "🎯 Cleanup complete. Your AWS account is now squeaky clean and budget-friendly!"

