#!/bin/bash

# === CREATE LOG FOLDER AND FILE ===
LOG_DIR="./delete-logs"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="$LOG_DIR/delete-log-$TIMESTAMP.txt"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "📜 Logging to $LOG_FILE"

# === AWS ACCOUNT SAFETY CHECK ===
echo "🔒 Checking AWS identity..."

account_id=$(aws sts get-caller-identity --query "Account" --output text)
user_arn=$(aws sts get-caller-identity --query "Arn" --output text)
caller_user=$(echo "$user_arn" | sed 's/^.*\///')
region=$(aws configure get region)

echo "🚨 You are logged in as:"
echo "👤 User:       $caller_user"
echo "🔗 ARN:        $user_arn"
echo "🏢 Account ID: $account_id"
echo "🌍 Region:     $region"
echo ""

read -p "❓ Is this the right account to wreak havoc on? (y/N): " confirm_account
if [[ "$confirm_account" != "y" && "$confirm_account" != "Y" ]]; then
  echo "🛑 Good call. Destruction postponed."
  exit 1
fi

# === LIST STACKS ===
echo "🕵️ Scanning for active CloudFormation stacks..."

all_stacks=$(aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query "StackSummaries[*].StackName" --output text)

if [ -z "$all_stacks" ]; then
  echo "🎉 No active stacks found. You're already zen."
else
  echo "🧨 Here are your active stacks:"
  i=1
  declare -a stack_options
  for stack in $all_stacks; do
    echo " [$i] 💣 $stack"
    stack_options[$i]=$stack
    ((i++))
  done

  echo ""
  read -p "🔢 Enter the numbers of the stacks you want to delete (e.g., 1 3 4), or press Enter to cancel: " selection

  declare -a selected_stacks
  for num in $selection; do
    if [[ "$num" =~ ^[0-9]+$ ]] && [[ -n "${stack_options[$num]}" ]]; then
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
  if [[ "$confirm_delete" != "y" && "$confirm_delete" != "Y" ]]; then
    echo "🙅‍♂️ Operation cancelled. Infrastructure spared."
    exit 1
  fi

  for stack in "${selected_stacks[@]}"; do
    echo "🗑️ Initiating deletion of stack: $stack ..."
    aws cloudformation delete-stack --stack-name "$stack"
  done

  echo "⏳ Watching the destruction unfold..."
  for stack in "${selected_stacks[@]}"; do
    echo "⏳ Waiting for stack: $stack to be deleted (max 5 minutes)..."
    for ((i=1; i<=20; i++)); do
      status=$(aws cloudformation describe-stacks \
        --stack-name "$stack" \
        --query "Stacks[0].StackStatus" \
        --output text 2>/dev/null)

      if [[ "$status" == "DELETE_COMPLETE" ]]; then
        echo "✅ Stack $stack is gone. Oblivion achieved."
        break
      elif [[ "$status" == "DELETE_FAILED" ]]; then
        echo "❌ Deletion failed for $stack. Something resisted. Maybe it's Skynet."
        break
      elif [[ "$status" == "" ]]; then
        echo "✅ Stack $stack no longer exists. Mission accomplished!"
        break
      else
        echo "⌛ Still deleting ($i/20)... status: $status"
        sleep 15
      fi
    done

    # Retry deletion just in case it was skipped earlier due to dependency
    echo "🔁 Double-checking $stack still exists..."
    aws cloudformation describe-stacks --stack-name "$stack" &>/dev/null
    if [ $? -eq 0 ]; then
      echo "🔁 Retrying deletion of stubborn stack: $stack ..."
      aws cloudformation delete-stack --stack-name "$stack"
    fi
  done
fi

# === CLEANUP OF ORPHANED RESOURCES ===
echo "🧹 Now sweeping for sneaky resources that love to charge silently..."

nat_ids=$(aws ec2 describe-nat-gateways --query "NatGateways[*].NatGatewayId" --output text)
if [ -n "$nat_ids" ]; then
  for nat in $nat_ids; do
    echo "🚪 Deleting NAT Gateway: $nat (it's not free, my friend)"
    aws ec2 delete-nat-gateway --nat-gateway-id "$nat"
  done
else
  echo "✅ No NAT Gateways detected. No hidden toll booths."
fi

eips=$(aws ec2 describe-addresses --query "Addresses[*].AllocationId" --output text)
if [ -n "$eips" ]; then
  for eip in $eips; do
    echo "📡 Releasing Elastic IP: $eip — it shall float freely."
    aws ec2 release-address --allocation-id "$eip"
  done
else
  echo "✅ No Elastic IPs haunting your bill."
fi

volumes=$(aws ec2 describe-volumes --filters Name=status,Values=available \
  --query "Volumes[*].VolumeId" --output text)
if [ -n "$volumes" ]; then
  for vol in $volumes; do
    echo "💽 Deleting unattached EBS volume: $vol — it's just sitting there!"
    aws ec2 delete-volume --volume-id "$vol"
  done
else
  echo "✅ No EBS volumes eating space (and money)."
fi

snapshots=$(aws ec2 describe-snapshots --owner-ids self \
  --query "Snapshots[*].SnapshotId" --output text)
if [ -n "$snapshots" ]; then
  for snap in $snapshots; do
    echo "📸 Deleting snapshot: $snap — because memories fade."
    aws ec2 delete-snapshot --snapshot-id "$snap"
  done
else
  echo "✅ No snapshots found. No nostalgia to pay for."
fi

lbs=$(aws elbv2 describe-load-balancers --query "LoadBalancers[*].LoadBalancerArn" --output text)
if [ -n "$lbs" ]; then
  for lb in $lbs; do
    echo "⚖️ Deleting load balancer: $lb — it’s just balancing nothing now."
    aws elbv2 delete-load-balancer --load-balancer-arn "$lb"
  done
else
  echo "✅ No load balancers detected. It's chaos, but cheap."
fi

echo "🎯 Cleanup complete. Your AWS account is now squeaky clean and budget-friendly!"

