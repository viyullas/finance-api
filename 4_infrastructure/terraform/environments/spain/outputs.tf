output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "rds_endpoint" {
  description = "RDS endpoint"
  value       = module.rds.db_instance_endpoint
}

output "kms_key_arn" {
  description = "KMS key ARN"
  value       = aws_kms_key.main.arn
}

output "external_secrets_role_arn" {
  description = "IAM role ARN for External Secrets Operator (IRSA)"
  value       = module.eks.external_secrets_role_arn
}

output "lb_controller_role_arn" {
  description = "IAM role ARN for AWS Load Balancer Controller (IRSA)"
  value       = module.eks.lb_controller_role_arn
}

output "account_id" {
  description = "AWS Account ID"
  value       = data.aws_caller_identity.current.account_id
}

output "ecr_registry" {
  description = "ECR registry URL for Helm values (image.registry)"
  value       = split("/", aws_ecr_repository.app.repository_url)[0]
}

output "ecr_repository_url" {
  description = "Full ECR repository URL (registry/repo)"
  value       = aws_ecr_repository.app.repository_url
}

output "acm_certificate_arn" {
  description = "ACM certificate ARN for the app Ingress"
  value       = aws_acm_certificate.app.arn
}

output "app_domain" {
  description = "Application domain name"
  value       = var.app_domain
}

output "rds_master_secret_arn" {
  description = "ARN of the RDS-managed master password secret"
  value       = module.rds.db_instance_master_user_secret_arn
}

output "app_secret_id" {
  description = "Secrets Manager secret name for application secrets (API_SECRET_KEY)"
  value       = aws_secretsmanager_secret.app_secrets.name
}

output "db_connection_endpoint" {
  description = "Database connection endpoint for applications (proxy if enabled, direct RDS otherwise)"
  value       = module.rds.db_connection_endpoint
}

output "external_dns_role_arn" {
  description = "IAM role ARN for external-dns (IRSA)"
  value       = module.eks.external_dns_role_arn
}

output "nat_public_ip" {
  description = "Public IP of the NAT Gateway (used by ArgoCD server to reach Mexico EKS endpoint)"
  value       = module.vpc.nat_public_ips[0]
}
