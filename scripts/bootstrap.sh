#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — One-time local bootstrap for the Hydrosat Dagster platform.
#
# This script is for initial setup only. Day-to-day deployments are handled
# by GitHub Actions (.github/workflows/). Run this once to:
#   1. Create the S3 backend bucket + DynamoDB lock table for Terraform state
#   2. Create the ECR repository for the pipeline image
#   3. Create the GitHub Actions OIDC IAM role
#   4. Verify prerequisites
#
# Prerequisites:
#   aws-cli >= 2.x  (configured with AdministratorAccess or equivalent)
#   terraform >= 1.6
#   kubectl, helm >= 3.x
#
# Usage:
#   export AWS_REGION=us-east-1
#   export GITHUB_ORG=hydrosat
#   export GITHUB_REPO=dagster-platform
#   ./scripts/bootstrap.sh
# =============================================================================

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT:-hydrosat}"
ENV="${ENV:-prod}"
GITHUB_ORG="${GITHUB_ORG:?Set GITHUB_ORG env var}"
GITHUB_REPO="${GITHUB_REPO:?Set GITHUB_REPO env var}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { echo -e "${GREEN}[$(date +%T)] ✓ $*${NC}"; }
info()    { echo -e "${CYAN}[$(date +%T)] → $*${NC}"; }
warn()    { echo -e "${YELLOW}[$(date +%T)] ⚠ $*${NC}"; }
die()     { echo -e "${RED}[$(date +%T)] ✗ $*${NC}" >&2; exit 1; }
divider() { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }

# ── Prerequisite checks ───────────────────────────────────────────────────────
divider
info "Checking prerequisites..."
command -v aws       >/dev/null 2>&1 || die "aws-cli not found"
command -v terraform >/dev/null 2>&1 || die "terraform not found"
command -v kubectl   >/dev/null 2>&1 || die "kubectl not found"
command -v helm      >/dev/null 2>&1 || die "helm not found"
command -v docker    >/dev/null 2>&1 || die "docker not found"

AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
AWS_PARTITION="aws"
log "AWS Account: ${AWS_ACCOUNT} | Region: ${AWS_REGION}"

# ── 1. Terraform remote state backend ────────────────────────────────────────
divider
STATE_BUCKET="${PROJECT}-terraform-state-${AWS_ACCOUNT}"
LOCK_TABLE="${PROJECT}-terraform-locks"

info "Creating Terraform S3 state bucket: ${STATE_BUCKET}"
if aws s3api head-bucket --bucket "${STATE_BUCKET}" 2>/dev/null; then
  warn "Bucket ${STATE_BUCKET} already exists — skipping."
else
  aws s3api create-bucket \
    --bucket "${STATE_BUCKET}" \
    --region "${AWS_REGION}" \
    $([ "${AWS_REGION}" != "us-east-1" ] && echo "--create-bucket-configuration LocationConstraint=${AWS_REGION}")

  aws s3api put-bucket-versioning \
    --bucket "${STATE_BUCKET}" \
    --versioning-configuration Status=Enabled

  aws s3api put-bucket-encryption \
    --bucket "${STATE_BUCKET}" \
    --server-side-encryption-configuration '{
      "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
    }'

  aws s3api put-public-access-block \
    --bucket "${STATE_BUCKET}" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

  log "S3 state bucket created and secured."
fi

info "Creating DynamoDB lock table: ${LOCK_TABLE}"
if aws dynamodb describe-table --table-name "${LOCK_TABLE}" --region "${AWS_REGION}" 2>/dev/null; then
  warn "DynamoDB table ${LOCK_TABLE} already exists — skipping."
else
  aws dynamodb create-table \
    --table-name "${LOCK_TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${AWS_REGION}"
  log "DynamoDB lock table created."
fi

# ── 2. ECR Repository ─────────────────────────────────────────────────────────
divider
ECR_REPO="${PROJECT}/dagster-pipeline"
info "Creating ECR repository: ${ECR_REPO}"
if aws ecr describe-repositories --repository-names "${ECR_REPO}" --region "${AWS_REGION}" 2>/dev/null; then
  warn "ECR repo ${ECR_REPO} already exists — skipping."
else
  aws ecr create-repository \
    --repository-name "${ECR_REPO}" \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 \
    --region "${AWS_REGION}"

  # Lifecycle policy: keep last 10 tagged images, expire untagged after 1 day
  aws ecr put-lifecycle-policy \
    --repository-name "${ECR_REPO}" \
    --lifecycle-policy-text '{
      "rules": [
        {
          "rulePriority": 1,
          "description": "Expire untagged images after 1 day",
          "selection": {"tagStatus": "untagged", "countType": "sinceImagePushed", "countUnit": "days", "countNumber": 1},
          "action": {"type": "expire"}
        },
        {
          "rulePriority": 2,
          "description": "Keep last 10 tagged images",
          "selection": {"tagStatus": "tagged", "tagPrefixList": ["v", "sha-"], "countType": "imageCountMoreThan", "countNumber": 10},
          "action": {"type": "expire"}
        }
      ]
    }' \
    --region "${AWS_REGION}"

  log "ECR repository created with lifecycle policy."
fi

ECR_REGISTRY="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# ── 3. GitHub Actions OIDC IAM Role ──────────────────────────────────────────
divider
info "Configuring GitHub Actions OIDC trust..."

GH_OIDC_PROVIDER="token.actions.githubusercontent.com"
OIDC_PROVIDER_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT}:oidc-provider/${GH_OIDC_PROVIDER}"

# Create OIDC provider if it doesn't exist
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_PROVIDER_ARN}" 2>/dev/null; then
  warn "GitHub OIDC provider already exists — skipping."
else
  aws iam create-open-id-connect-provider \
    --url "https://${GH_OIDC_PROVIDER}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1"
  log "GitHub OIDC provider created."
fi

GH_ACTIONS_ROLE="${PROJECT}-github-actions-role"
GH_SUBJECT_CLAIM="repo:${GITHUB_ORG}/${GITHUB_REPO}:*"

# Trust policy — scoped to this repo only
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_PROVIDER_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringLike": {
          "${GH_OIDC_PROVIDER}:sub": "${GH_SUBJECT_CLAIM}"
        },
        "StringEquals": {
          "${GH_OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF
)

if aws iam get-role --role-name "${GH_ACTIONS_ROLE}" 2>/dev/null; then
  warn "IAM role ${GH_ACTIONS_ROLE} already exists — updating trust policy."
  aws iam update-assume-role-policy \
    --role-name "${GH_ACTIONS_ROLE}" \
    --policy-document "${TRUST_POLICY}"
else
  aws iam create-role \
    --role-name "${GH_ACTIONS_ROLE}" \
    --assume-role-policy-document "${TRUST_POLICY}" \
    --description "GitHub Actions OIDC role for ${GITHUB_ORG}/${GITHUB_REPO}"
fi

# Attach policies needed by GitHub Actions workflows
for POLICY in \
  "arn:aws:iam::aws:policy/AdministratorAccess"; do
  # NOTE: In production, scope this down to least-privilege.
  # Split into separate roles per workflow (infra-deployer vs app-deployer).
  aws iam attach-role-policy \
    --role-name "${GH_ACTIONS_ROLE}" \
    --policy-arn "${POLICY}" 2>/dev/null || true
done

GH_ACTIONS_ROLE_ARN=$(aws iam get-role --role-name "${GH_ACTIONS_ROLE}" --query Role.Arn --output text)
log "GitHub Actions IAM role: ${GH_ACTIONS_ROLE_ARN}"

# ── 4. Enable Terraform backend in versions.tf ────────────────────────────────
divider
info "Patching terraform/versions.tf to enable S3 backend..."
BACKEND_BLOCK="  backend \"s3\" {
    bucket         = \"${STATE_BUCKET}\"
    key            = \"dagster-platform/terraform.tfstate\"
    region         = \"${AWS_REGION}\"
    dynamodb_table = \"${LOCK_TABLE}\"
    encrypt        = true
  }"

# Uncomment the backend block in versions.tf (sed in-place)
sed -i.bak \
  's|  # backend "s3"|  backend "s3"|g; s|  #   bucket|    bucket|g; s|  #   key|    key|g; s|  #   region|    region|g; s|  #   dynamodb_table|    dynamodb_table|g; s|  #   encrypt|    encrypt|g' \
  terraform/versions.tf
log "Backend block uncommented. Run 'terraform init -migrate-state' to migrate local state."

# ── Summary ───────────────────────────────────────────────────────────────────
divider
echo -e "${GREEN}Bootstrap complete! Add the following secrets to your GitHub repo:${NC}"
echo ""
echo "  Repository → Settings → Secrets and variables → Actions → New repository secret"
echo ""
printf "  %-35s %s\n" "Secret name" "Value"
printf "  %-35s %s\n" "-----------" "-----"
printf "  %-35s %s\n" "AWS_ROLE_ARN"                "${GH_ACTIONS_ROLE_ARN}"
printf "  %-35s %s\n" "AWS_REGION"                  "${AWS_REGION}"
printf "  %-35s %s\n" "ECR_REGISTRY"                "${ECR_REGISTRY}"
printf "  %-35s %s\n" "ECR_REPOSITORY"              "${ECR_REPO}"
printf "  %-35s %s\n" "TF_STATE_BUCKET"             "${STATE_BUCKET}"
printf "  %-35s %s\n" "SLACK_WEBHOOK_URL"           "<your-slack-webhook>"
echo ""
divider
