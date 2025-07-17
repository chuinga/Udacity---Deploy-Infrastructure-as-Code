#!/bin/bash

# SAFETY CHECK BEFORE NUKING ANYTHING

echo "🔒 Gathering AWS identity information..."

account_id=$(aws sts get-caller-identity --query "Account" --output text)
user_arn=$(aws sts get-caller-identity --query "Arn" --output text)
caller_user=$(echo "$user_arn" | sed 's/^.*\///')
region=$(aws configure get region)

echo ""
echo "🚨 You are currently authenticated as:"
echo "👤 User:       $caller_user"
echo "🔗 ARN:        $user_arn"
echo "🏢 Account ID: $account_id"
echo "🌍 Region:     $region"
echo ""

read -p "❓ Is this the correct AWS account to clean up? (y/N): " confirm_account
if [[ "$confirm_account" != "y" && "$confirm_account" != "Y" ]]; then
  echo "🛑 Aborting. Better safe than sorry."
  exit 1
fi

# NUKING EVERYTHING

echo "🕵️ Scanning for active CloudFormation stacks..."

# Get active stacks
stacks=$(aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query "StackSummaries[*].StackName" --output text)

if [ -z "$stacks" ]; then
  echo "🎉 No active stacks found. Your AWS account is cleaner than your kitchen."
else
  echo "🧨 The following stacks are about to face judgement day:"
  for stack in $stacks; do
    echo "💣 $stack"
  done

  read -p "⚠️ Are you sure you want to delete ALL these stacks? (y/N): " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "❌ Operation aborted. Nothing was harmed in the making of this script."
    exit 1
  fi

  for stack in $stacks; do
    echo "🗑️ Terminating stack: $stack ..."
    aws cloudformation delete-stack --stack-name "$stack"
  done

  echo "⏳ Waiting for the AWS gods to finish the purge..."
  for stack in $stacks; do
    aws cloudformation wait stack-delete-complete --stack-name "$stack"
    echo "✅ Stack $stack is now part of AWS history."
  done
fi

# Check for any remaining stacks
echo "🔁 Double-checking for stubborn stacks..."
remaining_stacks=$(aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query "StackSummaries[*].StackName" --output text)

if [ -n "$remaining_stacks" ]; then
  echo "😈 These naughty stacks refused to leave:"
  echo "$remaining_stacks"
  read -p "💪 Wanna give it one more try? (y/N): " try_again
  if [[ "$try_again" == "y" || "$try_again" == "Y" ]]; then
    for stack in $remaining_stacks; do
      echo "🔨 Retrying: $stack"
      aws cloudformation delete-stack --stack-name "$stack"
      aws cloudformation wait stack-delete-complete --stack-name "$stack"
      echo "✅ Finally removed: $stack"
    done
  fi
else
  echo "✅ No remaining stacks. AWS is as empty as your bank account after re:Invent."
fi

# Clean up orphaned cost-generating resources
echo ""
echo "🧹 Scanning for sneaky resources that are billing you behind your back..."

# NAT Gateways
nat_ids=$(aws ec2 describe-nat-gateways \
  --query "NatGateways[*].NatGatewayId" --output text)
if [ -n "$nat_ids" ]; then
  for nat in $nat_ids; do
    echo "🚪 Nuking NAT Gateway: $nat"
    aws ec2 delete-nat-gateway --nat-gateway-id "$nat"
  done
else
  echo "✅ No NAT Gateways detected. You’re not paying to route air."
fi

# Elastic IPs
eips=$(aws ec2 describe-addresses \
  --query "Addresses[*].AllocationId" --output text)
if [ -n "$eips" ]; then
  for eip in $eips; do
    echo "📡 Releasing Elastic IP: $eip"
    aws ec2 release-address --allocation-id "$eip"
  done
else
  echo "✅ No Elastic IPs floating around like haunted ghosts."
fi

# EBS Volumes
volumes=$(aws ec2 describe-volumes \
  --filters Name=status,Values=available \
  --query "Volumes[*].VolumeId" --output text)
if [ -n "$volumes" ]; then
  for vol in $volumes; do
    echo "💽 Deleting lonely EBS volume: $vol"
    aws ec2 delete-volume --volume-id "$vol"
  done
else
  echo "✅ No unattached EBS volumes draining your wallet."
fi

# Snapshots
snapshots=$(aws ec2 describe-snapshots --owner-ids self \
  --query "Snapshots[*].SnapshotId" --output text)
if [ -n "$snapshots" ]; then
  for snap in $snapshots; do
    echo "📸 Erasing snapshot: $snap (memories not included)"
    aws ec2 delete-snapshot --snapshot-id "$snap"
  done
else
  echo "✅ No snapshots. Nothing to remember. Nothing to pay."
fi

# Load Balancers
lbs=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[*].LoadBalancerArn" --output text)
if [ -n "$lbs" ]; then
  for lb in $lbs; do
    echo "⚖️ Deleting load balancer: $lb"
    aws elbv2 delete-load-balancer --load-balancer-arn "$lb"
  done
else
  echo "✅ No load balancers left balancing nothing."
fi

echo ""
echo "🚀 Cleanup complete. You're now safe from surprise AWS bills (for now)."
