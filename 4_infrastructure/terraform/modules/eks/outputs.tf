output "cluster_id" {
  description = "EKS cluster ID"
  value       = module.eks.cluster_id
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "EKS cluster CA data"
  value       = module.eks.cluster_certificate_authority_data
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA"
  value       = module.eks.oidc_provider_arn
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "external_secrets_role_arn" {
  description = "IAM role ARN for External Secrets Operator"
  value       = module.external_secrets_irsa.iam_role_arn
}

output "lb_controller_role_arn" {
  description = "IAM role ARN for AWS Load Balancer Controller"
  value       = module.lb_controller_irsa.iam_role_arn
}

output "external_dns_role_arn" {
  description = "IAM role ARN for external-dns (IRSA)"
  value       = module.external_dns_irsa.iam_role_arn
}

output "node_security_group_id" {
  description = "Security group ID attached to EKS nodes"
  value       = module.eks.node_security_group_id
}
