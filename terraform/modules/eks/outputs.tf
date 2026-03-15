output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "EKS cluster API server endpoint"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority data for the cluster"
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL for IRSA"
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "cluster_autoscaler_role_arn" {
  description = "IAM role ARN for cluster autoscaler IRSA"
  value       = aws_iam_role.cluster_autoscaler.arn
}

output "aws_lbc_role_arn" {
  description = "IAM role ARN for AWS Load Balancer Controller IRSA"
  value       = aws_iam_role.aws_lbc.arn
}

output "node_group_system_name" {
  description = "Name of the system node group"
  value       = aws_eks_node_group.system.node_group_name
}

output "node_group_workers_name" {
  description = "Name of the workers node group"
  value       = aws_eks_node_group.workers.node_group_name
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster control plane"
  value       = aws_security_group.cluster.id
}

output "node_security_group_id" {
  description = <<-EOT
    Security group ID for EKS nodes (the cluster SG EKS attaches automatically
    to all managed node group instances). Use this in RDS ingress rules so only
    nodes — not the control plane ENIs — can reach PostgreSQL.
  EOT
  # EKS automatically creates and attaches a cluster-level SG to all managed
  # node groups. We expose the SG we provided to vpc_config so downstream
  # resources (RDS) can allow traffic from EKS nodes.
  value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}
