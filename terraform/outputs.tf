output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  description = "Command to update local kubeconfig"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint"
  value       = module.rds.db_instance_endpoint
}

output "rds_secret_arn" {
  description = "ARN of the Secrets Manager secret with DB credentials"
  value       = module.rds.db_secret_arn
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnet_ids
}

output "github_actions_role_arn" {
  description = "IAM role ARN for GitHub Actions OIDC — set as AWS_ROLE_ARN secret"
  value       = module.github_oidc.github_actions_role_arn
}

output "dagster_logs_bucket" {
  description = "S3 bucket name for Dagster compute logs"
  value       = aws_s3_bucket.dagster_logs.bucket
}

output "dagster_sns_topic_arn" {
  description = "SNS topic ARN for Dagster failure alerts"
  value       = aws_sns_topic.dagster_alerts.arn
}

output "dagster_sa_role_arn" {
  description = "IRSA role ARN for Dagster service account"
  value       = aws_iam_role.dagster_sa.arn
}
