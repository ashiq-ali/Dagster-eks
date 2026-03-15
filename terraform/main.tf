provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "hydrosat/dagster-platform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ── GitHub Actions OIDC Role ──────────────────────────────────────────────────

module "github_oidc" {
  source = "./modules/github-oidc"

  project     = var.project
  environment = var.environment
  github_org  = var.github_org
  github_repo = var.github_repo

  create_oidc_provider = false # Already created by bootstrap.sh — do not recreate

  tf_state_bucket = "${var.project}-terraform-state-${data.aws_caller_identity.current.account_id}"
  tf_lock_table   = "${var.project}-terraform-locks"
}

# ── VPC ───────────────────────────────────────────────────────────────────────

module "vpc" {
  source = "./modules/vpc"

  project              = var.project
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  azs                  = var.azs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  cluster_name         = var.cluster_name
}

# ── EKS ─────────────────────────────────────────────────────────────────────── 

module "eks" {
  source = "./modules/eks"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids

  system_node_instance_types = var.system_node_instance_types
  system_node_desired        = var.system_node_desired
  system_node_min            = var.system_node_min
  system_node_max            = var.system_node_max

  worker_node_instance_types = var.worker_node_instance_types
  worker_node_desired        = var.worker_node_desired
  worker_node_min            = var.worker_node_min
  worker_node_max            = var.worker_node_max
}

# ── RDS ───────────────────────────────────────────────────────────────────────

module "rds" {
  source = "./modules/rds"

  project     = var.project
  environment = var.environment

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  # Allow EKS nodes to connect to RDS on port 5432.
  # Use the EKS-managed cluster SG (attached to all managed node group instances)
  # rather than the custom control-plane SG, so only worker/system node pods
  # can reach PostgreSQL — not the control plane ENIs.
  eks_security_group_id = module.eks.node_security_group_id

  db_instance_class        = var.db_instance_class
  db_name                  = var.db_name
  db_username              = var.db_username
  db_allocated_storage     = var.db_allocated_storage
  db_max_allocated_storage = var.db_max_allocated_storage
  db_multi_az              = var.db_multi_az

  depends_on = [module.vpc]
}

# ── Kubernetes / Helm providers (configured after cluster creation) ───────────

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

# ── S3: Dagster compute log storage ──────────────────────────────────────────
# Stores stdout/stderr from every op execution — accessible in the Dagit logs panel.

resource "aws_s3_bucket" "dagster_logs" {
  bucket = "${var.project}-dagster-logs-${var.environment}-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name        = "${var.project}-dagster-logs-${var.environment}"
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_s3_bucket_versioning" "dagster_logs" {
  bucket = aws_s3_bucket.dagster_logs.id
  versioning_configuration { status = "Disabled" } # Logs don't need versioning
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dagster_logs" {
  bucket = aws_s3_bucket.dagster_logs.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "dagster_logs" {
  bucket                  = aws_s3_bucket.dagster_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "dagster_logs" {
  bucket = aws_s3_bucket.dagster_logs.id
  rule {
    id     = "expire-old-logs"
    status = "Enabled"
    filter { prefix = "compute-logs/" }
    expiration { days = 90 }
  }
}

# ── SNS: Dagster alert topic ──────────────────────────────────────────────────
# Belt-and-suspenders alerting — fires from the Dagster run_failure_alert_sensor
# independently of Prometheus/Alertmanager.

resource "aws_sns_topic" "dagster_alerts" {
  name              = "${var.project}-dagster-alerts"
  kms_master_key_id = "alias/aws/sns"

  tags = {
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_sns_topic_subscription" "dagster_alerts_email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.dagster_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── IRSA: Dagster service account (S3 logs + SNS publish) ────────────────────

data "aws_iam_policy_document" "dagster_sa_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:dagster:dagster"]
    }

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
  }
}

resource "aws_iam_role" "dagster_sa" {
  name               = "${var.cluster_name}-dagster-sa-role"
  assume_role_policy = data.aws_iam_policy_document.dagster_sa_assume.json

  tags = {
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "dagster_sa" {
  name = "${var.cluster_name}-dagster-sa-policy"
  role = aws_iam_role.dagster_sa.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ComputeLogStorage"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.dagster_logs.arn,
          "${aws_s3_bucket.dagster_logs.arn}/*",
        ]
      },
      {
        Sid      = "SNSAlerts"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = [aws_sns_topic.dagster_alerts.arn]
      },
      {
        Sid      = "STSIdentity"
        Effect   = "Allow"
        Action   = ["sts:GetCallerIdentity"]
        Resource = "*"
      }
    ]
  })
}

# ── Kubernetes Namespaces ─────────────────────────────────────────────────────

resource "kubernetes_namespace" "dagster" {
  metadata {
    name = "dagster"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "monitoring"                   = "enabled"
    }
  }

  depends_on = [module.eks]
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [module.eks]
}

# ── Kubernetes Secret: Dagster PostgreSQL credentials ─────────────────────────
# Secret is populated from AWS Secrets Manager at apply time.
# In production, use the External Secrets Operator for rotation support.

data "aws_secretsmanager_secret_version" "db" {
  secret_id  = module.rds.db_secret_arn
  depends_on = [module.rds]
}

locals {
  db_creds = jsondecode(data.aws_secretsmanager_secret_version.db.secret_string)
}

resource "kubernetes_secret" "dagster_postgresql" {
  metadata {
    name      = "dagster-postgresql-secret"
    namespace = kubernetes_namespace.dagster.metadata[0].name

    # Add Helm labels and annotations so Helm can adopt this secret
    labels = {
      "app.kubernetes.io/managed-by" = "Helm"
    }

    annotations = {
      "meta.helm.sh/release-name"      = "dagster"
      "meta.helm.sh/release-namespace" = "dagster"
    }
  }

  data = {
    postgresql-password = local.db_creds.password
    connection-string   = local.db_creds.url
  }

  type = "Opaque"
}

# ── Helm: AWS Load Balancer Controller ────────────────────────────────────────

resource "helm_release" "aws_lbc" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.7.2"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.eks.aws_lbc_role_arn
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  # Single replica — t3.small has 11-pod limit; 2 replicas (default) wastes a slot.
  set {
    name  = "replicaCount"
    value = "1"
  }

  # Wait for LBC pods to be fully Running before Terraform marks this complete.
  # Without this, the mutating webhook is registered but has no endpoints,
  # causing any subsequent Helm chart that deploys Services to fail.
  wait          = true
  wait_for_jobs = true
  timeout       = 300

  depends_on = [module.eks]
}

# ── Helm: Cluster Autoscaler ─────────────────────────────────────────────────

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  namespace  = "kube-system"
  version    = "9.37.0"

  set {
    name  = "autoDiscovery.clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "awsRegion"
    value = var.aws_region
  }

  set {
    name  = "cloudProvider"
    value = "aws"
  }

  set {
    name  = "rbac.serviceAccount.create"
    value = "true"
  }

  set {
    name  = "rbac.serviceAccount.name"
    value = "cluster-autoscaler"
  }

  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.eks.cluster_autoscaler_role_arn
  }

  set {
    name  = "extraArgs.balance-similar-node-groups"
    value = "true"
  }

  set {
    name  = "extraArgs.expander"
    value = "least-waste"
  }

  set {
    name  = "extraArgs.skip-nodes-with-local-storage"
    value = "false"
  }

  set {
    name  = "extraArgs.skip-nodes-with-system-pods"
    value = "false"
  }

  set {
    name  = "nodeSelector.role"
    value = "system"
  }

  set {
    name  = "tolerations[0].key"
    value = "role"
  }

  set {
    name  = "tolerations[0].operator"
    value = "Equal"
  }

  set {
    name  = "tolerations[0].value"
    value = "system"
  }

  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }

  depends_on = [module.eks, helm_release.aws_lbc]
}

# NOTE: Dagster and kube-prometheus-stack are intentionally NOT managed by Terraform.
# They are deployed by CI (deploy-app.yml) via Helm so that infra values (IRSA ARN,
# S3 bucket, SNS ARN, RDS creds) can be fetched at deploy time from AWS APIs.