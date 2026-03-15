variable "aws_region" {
  description = "AWS region where all resources will be deployed"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment (dev / staging / prod)"
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging, or prod."
  }
}

variable "project" {
  description = "Project name used as a prefix for all resource names"
  type        = string
  default     = "hydrosat"
}

# ── VPC ──────────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Availability zones. EKS and RDS both require subnets in at least 2 AZs."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ — ALB, NAT Gateways)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ — EKS nodes, RDS)"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

# ── EKS ──────────────────────────────────────────────────────────────────────

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "hydrosat-dagster"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.30"
}

variable "system_node_instance_types" {
  description = <<-EOT
    Instance types for the system node group (Dagster webserver, daemon,
    user code deployments, ingress controller, monitoring stack).
  EOT
  type        = list(string)
  default     = ["t3.medium"]
}

variable "system_node_desired" {
  description = "Desired node count for the system node group"
  type        = number
  default     = 2
}

variable "system_node_min" {
  description = "Minimum node count for the system node group"
  type        = number
  default     = 2
}

variable "system_node_max" {
  description = "Maximum node count for the system node group"
  type        = number
  default     = 4
}

variable "worker_node_instance_types" {
  description = <<-EOT
    Instance types for the worker node group (Dagster K8s executor pods).
    t3.medium (2 vCPU / 4 GiB) for POC; upgrade to m5.xlarge for production.
    Multiple types improve spot availability and reduce interruption risk.
  EOT
  type        = list(string)
  default     = ["t3.medium", "t3a.medium"] # multiple types → better spot availability
}

variable "worker_node_desired" {
  description = "Desired node count for the worker node group (scales to 0 when idle)"
  type        = number
  default     = 0
}

variable "worker_node_min" {
  description = "Minimum node count for the worker node group"
  type        = number
  default     = 0
}

variable "worker_node_max" {
  description = "Maximum node count for the worker node group"
  type        = number
  default     = 10
}

# ── RDS ──────────────────────────────────────────────────────────────────────

variable "db_instance_class" {
  description = <<-EOT
    RDS instance class for Dagster PostgreSQL metadata store.
    db.t3.medium provides adequate headroom for Dagster metadata workloads,
    operational queries, and Multi-AZ failover in production.
  EOT
  type        = string
  default     = "db.t3.medium"
}

variable "db_name" {
  description = "Name of the Dagster PostgreSQL database"
  type        = string
  default     = "dagster"
}

variable "db_username" {
  description = "Master username for the RDS instance"
  type        = string
  default     = "dagster"
  sensitive   = true
}

variable "db_allocated_storage" {
  description = "Initial allocated storage in GiB for the RDS instance"
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Maximum storage autoscaling ceiling in GiB"
  type        = number
  default     = 100
}

variable "db_multi_az" {
  description = "Enable Multi-AZ deployment for the RDS instance"
  type        = bool
  default     = true
}

# ── Alerting ─────────────────────────────────────────────────────────────────

variable "slack_webhook_url" {
  description = "Slack incoming webhook URL for Alertmanager notifications"
  type        = string
  default     = ""
  sensitive   = true
}

variable "alert_email" {
  description = "Email address for on-call engineer alert notifications"
  type        = string
  default     = "oncall@hydrosat.com"
}

# ── GitHub ────────────────────────────────────────────────────────────────────

variable "github_org" {
  description = "GitHub organisation name — used to scope the OIDC trust policy"
  type        = string
  default     = "ashiq-ali"
}

variable "github_repo" {
  description = "GitHub repository name — used to scope the OIDC trust policy"
  type        = string
  default     = "AWS-DevOps"
}
