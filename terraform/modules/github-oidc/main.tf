# GitHub Actions OIDC IAM Role
# Enables GitHub Actions to assume an AWS IAM role via short-lived tokens —
# no long-lived AWS credentials stored in GitHub Secrets.
#
# How it works:
#   1. GitHub Actions requests a JWT from GitHub's OIDC provider
#   2. aws-actions/configure-aws-credentials exchanges it for AWS STS credentials
#   3. STS validates the JWT signature against the OIDC provider thumbprint
#   4. The trust policy condition ensures only THIS repo can assume the role

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  oidc_provider_url = "token.actions.githubusercontent.com"
  oidc_provider_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_provider_url}"
}

# ── OIDC Provider (idempotent — one per account) ─────────────────────────────

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://${local.oidc_provider_url}"
  client_id_list = ["sts.amazonaws.com"]
  # GitHub's OIDC thumbprint — stable, documented by GitHub
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── IAM Role — scoped to specific repo ───────────────────────────────────────

resource "aws_iam_role" "github_actions" {
  name        = "${var.project}-github-actions-role"
  description = "Assumed by GitHub Actions OIDC for ${var.github_org}/${var.github_repo}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GitHubOIDCTrust"
        Effect = "Allow"
        Principal = {
          Federated = local.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # Lock to specific org/repo — wildcards allow branch/tag flexibility
            "${local.oidc_provider_url}:sub" = "repo:${var.github_org}/${var.github_repo}:*"
          }
        }
      }
    ]
  })

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    GithubOrg   = var.github_org
    GithubRepo  = var.github_repo
  }
}

# ── Separate roles for least-privilege separation ─────────────────────────────
# Production pattern: split into infra-deployer vs app-deployer roles.
# infra-deployer: terraform apply permissions (EKS, VPC, RDS, IAM)
# app-deployer:   ECR push + helm upgrade + kubectl (no infra changes)

resource "aws_iam_policy" "infra_deployer" {
  name        = "${var.project}-github-infra-deployer"
  description = "Terraform apply permissions for GitHub Actions infra workflow"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Terraform state bucket access
      {
        Sid    = "TerraformState"
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${var.tf_state_bucket}",
          "arn:aws:s3:::${var.tf_state_bucket}/*"
        ]
      },
      # DynamoDB state locking
      {
        Sid    = "TerraformLock"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem", "dynamodb:PutItem",
          "dynamodb:DeleteItem", "dynamodb:DescribeTable"
        ]
        Resource = "arn:aws:dynamodb:*:*:table/${var.tf_lock_table}"
      },
      # EKS management
      {
        Sid      = "EKS"
        Effect   = "Allow"
        Action   = ["eks:*"]
        Resource = "*"
      },
      # EC2 / VPC
      {
        Sid      = "VPC"
        Effect   = "Allow"
        Action   = ["ec2:*", "elasticloadbalancing:*"]
        Resource = "*"
      },
      # RDS
      {
        Sid      = "RDS"
        Effect   = "Allow"
        Action   = ["rds:*"]
        Resource = "*"
      },
      # IAM — scoped to project-prefixed resources only.
      # CreateRole and AttachRolePolicy are restricted to project-specific resource ARNs,
      # preventing privilege escalation to arbitrary admin roles.
      # Read-only IAM actions are broader to support terraform plan/show.
      {
        Sid    = "IAMReadOnly"
        Effect = "Allow"
        Action = [
          "iam:GetRole", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions",
          "iam:GetOpenIDConnectProvider", "iam:ListOpenIDConnectProviders",
          "iam:GetInstanceProfile"
        ]
        Resource = "*"
      },
      {
        Sid    = "IAMWriteScopedToProject"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:AttachRolePolicy",
          "iam:DetachRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
          "iam:PassRole", "iam:CreatePolicy", "iam:DeletePolicy",
          "iam:CreatePolicyVersion", "iam:DeletePolicyVersion",
          "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
          "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
          "iam:UpdateAssumeRolePolicy", "iam:CreateServiceLinkedRole"
        ]
        # Scoped to project-prefixed roles and policies — prevents creating arbitrary admin roles
        Resource = [
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project}-*",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project}-*",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/${var.project}-*",
          # Allow creating EKS/EBS/LBC service-linked roles (AWS-managed names)
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/*"
        ]
      },
      {
        Sid    = "IAMOIDCProvider"
        Effect = "Allow"
        Action = [
          "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
          "iam:UpdateOpenIDConnectProviderThumbprint", "iam:AddClientIDToOpenIDConnectProvider"
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/*"
      },
      # KMS
      {
        Sid      = "KMS"
        Effect   = "Allow"
        Action   = ["kms:*"]
        Resource = "*"
      },
      # Secrets Manager
      {
        Sid      = "SecretsManager"
        Effect   = "Allow"
        Action   = ["secretsmanager:*"]
        Resource = "*"
      },
      # CloudWatch logs (VPC flow logs, EKS control plane logs)
      {
        Sid      = "CloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:*", "cloudwatch:*"]
        Resource = "*"
      },
      # Auto Scaling
      {
        Sid      = "AutoScaling"
        Effect   = "Allow"
        Action   = ["autoscaling:*"]
        Resource = "*"
      }
    ]
  })

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

resource "aws_iam_policy" "app_deployer" {
  name        = "${var.project}-github-app-deployer"
  description = "ECR push + EKS Helm deploy permissions for GitHub Actions app workflow"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ECR — push pipeline images
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:DescribeImages",
          "ecr:DescribeRepositories"
        ]
        Resource = "*"
      },
      # EKS — update kubeconfig + describe cluster
      {
        Sid      = "EKSDescribe"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster", "eks:ListClusters"]
        Resource = "*"
      },
      # Secrets Manager — read DB credentials at deploy time
      {
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = "arn:aws:secretsmanager:*:*:secret:${var.project}*"
      },
      # STS — for kubeconfig token generation
      {
        Sid      = "STS"
        Effect   = "Allow"
        Action   = ["sts:GetCallerIdentity"]
        Resource = "*"
      }
    ]
  })

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

# Attach both policies to the single GitHub Actions role
# (In strict prod environments, create two separate roles — one per workflow)
resource "aws_iam_role_policy_attachment" "infra_deployer" {
  policy_arn = aws_iam_policy.infra_deployer.arn
  role       = aws_iam_role.github_actions.name
}

resource "aws_iam_role_policy_attachment" "app_deployer" {
  policy_arn = aws_iam_policy.app_deployer.arn
  role       = aws_iam_role.github_actions.name
}
