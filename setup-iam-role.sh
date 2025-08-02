#!/bin/bash

# Setup IAM service-linked role for Global Accelerator and Route 53
set -e

# Use appropriate directories based on user privileges
if [[ $EUID -eq 0 ]]; then
    SCRIPT_DIR="/var/lib/aws-global-accelerator-script"
else
    SCRIPT_DIR="$HOME/.aws-global-accelerator-script"
fi

ROLE_FILE="$SCRIPT_DIR/role-name"

# Check if role already exists
if [[ -f "$ROLE_FILE" ]]; then
    ROLE_NAME=$(cat "$ROLE_FILE")
    if aws iam get-role --role-name "$ROLE_NAME" --no-cli-pager >/dev/null 2>&1; then
        echo "IAM role $ROLE_NAME already exists"
        exit 0
    fi
fi

# Generate unique identifier
UNIQUE_ID=$(openssl rand -hex 4)
ROLE_NAME="ec2-global-accelerator-r53-$UNIQUE_ID"

echo "Creating IAM role: $ROLE_NAME"

# Create trust policy
TRUST_POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF
)

# Create permissions policy
PERMISSIONS_POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "globalaccelerator:*",
                "route53:ChangeResourceRecordSets",
                "route53:GetChange",
                "route53:ListResourceRecordSets",
                "ec2:DescribeNetworkInterfaces",
                "ec2:DescribeInstances"
            ],
            "Resource": "*"
        }
    ]
}
EOF
)

POLICY_NAME="GlobalAcceleratorRoute53Policy-$UNIQUE_ID"

# Create managed policy
POLICY_ARN=$(aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document "$PERMISSIONS_POLICY" \
    --query 'Policy.Arn' --output text --no-cli-pager)

# Create role
aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --no-cli-pager

# Attach policy to role
aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "$POLICY_ARN" \
    --no-cli-pager

# Create script directory and description
mkdir -p "$SCRIPT_DIR"
echo "Files created by AWS Global Accelerator automation scripts for managing accelerator endpoints and Route 53 DNS records." > "$SCRIPT_DIR/README.txt"

# Store role name and policy name
echo "$ROLE_NAME" > "$ROLE_FILE"
echo "$POLICY_NAME" > "$SCRIPT_DIR/policy-name"

echo "IAM role $ROLE_NAME and policy $POLICY_NAME created successfully"