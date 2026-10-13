#!/usr/bin/env bash
set -euo pipefail

# Please fill in below
export VPC_ID=vpc-
export SUBNET_ID1=subnet-
export SUBNET_ID2=subnet-

export DB_PASSWORD=
export AWS_REGION=
export CERTIFICATE_ARN=arn:aws:acm:
export STACK_NAME=
export PWB_LICENSE=
export PWB_VERSION=2026.09.0-174.pro3
export PWB_VERSION_SHORT=2026.09.0

export CONFIG_BUCKET=
export CONFIG_PREFIX=config/rstudio
export SESSION_CALLBACK_ADDRESS="https://workbench.pcluster.soleng.posit.it"
# ---

export VPC_ID=vpc-02c67d4d1c8fb03b0
export SUBNET_ID1=subnet-055971c5dfcef6442
export SUBNET_ID2=subnet-00f276a6051834ff2

export DB_PASSWORD=Testme1234
export AWS_REGION=eu-west-1
export CERTIFICATE_ARN=arn:aws:acm:eu-west-1:637485797898:certificate/aee6d101-3558-45a1-a3c5-69663452475f
export STACK_NAME="michael98"
export PWB_LICENSE=KAZG-PPFB-HH8S-SE8A-CP9J-F7GW-YWTA
export PWB_VERSION=2026.09.0-174.pro3
export PWB_VERSION_SHORT=2026.09.0

export CONFIG_BUCKET=hpc-scripts1234
export CONFIG_PREFIX=config/rstudio
export SESSION_CALLBACK_ADDRESS="https://pcs.pcluster.soleng.posit.it"

REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-hpc-cluster}"
RDS_STACK_NAME="${STACK_NAME}-rds"
SCRIPT_DIR="$(dirname "$0")"

echo "Looking up PCS Ubuntu 24.04 AMI in ${REGION}..."
AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=aws-pcs-ready-dlami-base-ubuntu2404-x86_64*" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text \
  --region "$REGION")

if [ "$AMI_ID" = "None" ] || [ -z "$AMI_ID" ]; then
  echo "ERROR: No PCS Ubuntu 24.04 AMI found in ${REGION}" >&2
  exit 1
fi

echo "Found AMI: ${AMI_ID}"

# --- Deploy RDS ---

if [ -z "${DB_PASSWORD:-}" ]; then
  echo "ERROR: DB_PASSWORD environment variable is required for RDS deployment" >&2
  exit 1
fi

echo "Deploying RDS stack: ${RDS_STACK_NAME}..."
aws cloudformation deploy \
  --template-file "${SCRIPT_DIR}/rds.yaml" \
  --stack-name "$RDS_STACK_NAME" \
  --parameter-overrides \
    VpcId="${VPC_ID}" \
    SubnetId1="${SUBNET_ID1}" \
    SubnetId2="${SUBNET_ID2}" \
    DBMasterPassword="${DB_PASSWORD}" \
  --region "$REGION"

echo "RDS stack deployed. Fetching outputs..."
RDS_SG_ID=$(aws cloudformation describe-stacks \
  --stack-name "$RDS_STACK_NAME" \
  --query 'Stacks[0].Outputs[?OutputKey==`RdsSecurityGroupId`].OutputValue' \
  --output text \
  --region "$REGION")

RDS_ENDPOINT=$(aws cloudformation describe-stacks \
  --stack-name "$RDS_STACK_NAME" \
  --query 'Stacks[0].Outputs[?OutputKey==`RdsEndpoint`].OutputValue' \
  --output text \
  --region "$REGION")

echo "RDS Security Group: ${RDS_SG_ID}"
echo "RDS Endpoint: ${RDS_ENDPOINT}"

# --- Deploy PCS cluster ---

VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0].CidrBlock' --output text --region "$REGION")
echo "VPC CIDR: ${VPC_CIDR}"

OVERRIDES="AmiId=${AMI_ID} ClusterName=${STACK_NAME}-cluster"
OVERRIDES="${OVERRIDES} RdsSecurityGroupId=${RDS_SG_ID}"
OVERRIDES="${OVERRIDES} RdsEndpoint=${RDS_ENDPOINT}"
OVERRIDES="${OVERRIDES} RdsPassword=${DB_PASSWORD}"
OVERRIDES="${OVERRIDES} VpcCidr=${VPC_CIDR}"
[ -n "${VPC_ID:-}" ] && OVERRIDES="${OVERRIDES} ExistingVpcId=${VPC_ID}"
[ -n "${SUBNET_ID1:-}" ] && OVERRIDES="${OVERRIDES} ExistingSubnetId1=${SUBNET_ID1}"
[ -n "${SUBNET_ID2:-}" ] && OVERRIDES="${OVERRIDES} ExistingSubnetId2=${SUBNET_ID2}"
[ -n "${SECURITY_GROUP_ID:-}" ] && OVERRIDES="${OVERRIDES} ExistingSecurityGroupId=${SECURITY_GROUP_ID}"
[ -n "${CERTIFICATE_ARN:-}" ] && OVERRIDES="${OVERRIDES} CertificateArn=${CERTIFICATE_ARN}"
[ -n "${CONFIG_BUCKET:-}" ] && OVERRIDES="${OVERRIDES} ConfigBucket=${CONFIG_BUCKET}"
[ -n "${CONFIG_PREFIX:-}" ] && OVERRIDES="${OVERRIDES} ConfigPrefix=${CONFIG_PREFIX}"
[ -n "${PWB_LICENSE:-}" ] && OVERRIDES="${OVERRIDES} PwbLicense=${PWB_LICENSE}"
[ -n "${PWB_VERSION:-}" ] && OVERRIDES="${OVERRIDES} PwbVersion=${PWB_VERSION}"
[ -n "${PWB_VERSION_SHORT:-}" ] && OVERRIDES="${OVERRIDES} PwbVersionShort=${PWB_VERSION_SHORT}"
[ -n "${MAX_GPU_NODES:-}" ] && OVERRIDES="${OVERRIDES} MaxGpuNodes=${MAX_GPU_NODES}"

# Template exceeds the 51,200-byte inline limit, so deploy stages it in S3. The bucket must be
# in the stack's region (deploy builds the URL from the regional endpoint), so CONFIG_BUCKET
# can't be reused in general; default to a per-account/region bucket, created on first use.
if [ -z "${CFN_BUCKET:-}" ]; then
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
  CFN_BUCKET="cfn-templates-${ACCOUNT_ID}-${REGION}"
fi
if ! aws s3api head-bucket --bucket "$CFN_BUCKET" --region "$REGION" 2>/dev/null; then
  echo "Creating template bucket ${CFN_BUCKET}..."
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$CFN_BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$CFN_BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
fi

echo "Deploying PCS stack: ${STACK_NAME}..."
aws cloudformation deploy \
  --template-file "${SCRIPT_DIR}/pcs-cluster.yaml" \
  --stack-name "$STACK_NAME" \
  --s3-bucket "$CFN_BUCKET" --s3-prefix "$STACK_NAME" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides $OVERRIDES \
  --region "$REGION"

echo "PCS stack deployed."

echo ""
echo "=== Deployment complete ==="
echo ""
echo "PCS stack outputs:"
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs' \
  --output table \
  --region "$REGION"

echo ""
echo "RDS stack outputs:"
aws cloudformation describe-stacks \
  --stack-name "$RDS_STACK_NAME" \
  --query 'Stacks[0].Outputs' \
  --output table \
  --region "$REGION"
