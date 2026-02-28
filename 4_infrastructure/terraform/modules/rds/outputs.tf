output "db_instance_endpoint" {
  description = "RDS instance endpoint"
  value       = module.rds.db_instance_endpoint
}

output "db_instance_id" {
  description = "RDS instance ID"
  value       = module.rds.db_instance_identifier
}

output "db_instance_arn" {
  description = "RDS instance ARN"
  value       = module.rds.db_instance_arn
}

output "db_security_group_id" {
  description = "Security group ID for RDS"
  value       = aws_security_group.rds.id
}

output "db_instance_master_user_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the RDS master password"
  value       = module.rds.db_instance_master_user_secret_arn
}

output "db_proxy_endpoint" {
  description = "RDS Proxy endpoint (empty if proxy is disabled)"
  value       = var.rds_proxy_enabled ? aws_db_proxy.this[0].endpoint : ""
}

output "db_connection_endpoint" {
  description = "Endpoint for application connections: proxy if enabled, direct RDS otherwise"
  value       = var.rds_proxy_enabled ? aws_db_proxy.this[0].endpoint : module.rds.db_instance_address
}
