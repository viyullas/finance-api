variable "aws_region" {
  description = "AWS region for this environment"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name prefix for all resources"
  type        = string
  default     = "pluxee-mexico"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "production"
}

variable "region_name" {
  description = "Human-readable region identifier"
  type        = string
  default     = "mexico"
}

variable "data_residency" {
  description = "Data residency classification (EU, MX, etc.)"
  type        = string
  default     = "MX"
}

variable "compliance" {
  description = "Compliance framework (GDPR, LeyFederalMX, etc.)"
  type        = string
  default     = "LeyFederalMX"
}

# --- Networking ---

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "private_subnets" {
  description = "Private subnet CIDR blocks"
  type        = list(string)
  default     = ["10.20.1.0/24", "10.20.2.0/24", "10.20.3.0/24"]
}

variable "public_subnets" {
  description = "Public subnet CIDR blocks"
  type        = list(string)
  default     = ["10.20.11.0/24", "10.20.12.0/24", "10.20.13.0/24"]
}

variable "database_subnets" {
  description = "Database subnet CIDR blocks"
  type        = list(string)
  default     = ["10.20.21.0/24", "10.20.22.0/24", "10.20.23.0/24"]
}

# --- NAT Gateway ---

variable "single_nat_gateway" {
  description = "Use a single NAT Gateway instead of one per AZ (saves cost, reduces availability)"
  type        = bool
  default     = true
}

# --- EKS ---

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the EKS API server public endpoint"
  type        = list(string)
  default     = ["83.33.97.233/32"]
}

variable "system_node_instance_types" {
  description = "EC2 instance types for system node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "system_node_min_size" {
  description = "Minimum number of system nodes"
  type        = number
  default     = 2
}

variable "system_node_max_size" {
  description = "Maximum number of system nodes"
  type        = number
  default     = 3
}

variable "system_node_desired_size" {
  description = "Desired number of system nodes"
  type        = number
  default     = 2
}

variable "app_node_instance_types" {
  description = "EC2 instance types for application node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "app_node_min_size" {
  description = "Minimum number of application nodes"
  type        = number
  default     = 2
}

variable "app_node_max_size" {
  description = "Maximum number of application nodes"
  type        = number
  default     = 6
}

variable "app_node_desired_size" {
  description = "Desired number of application nodes"
  type        = number
  default     = 2
}

# --- RDS Proxy ---

variable "rds_proxy_enabled" {
  description = "Enable RDS Proxy for connection pooling"
  type        = bool
  default     = true
}

# --- RDS ---

variable "rds_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.micro"
}

variable "rds_allocated_storage" {
  description = "RDS allocated storage in GB"
  type        = number
  default     = 20
}

variable "rds_max_allocated_storage" {
  description = "RDS max allocated storage for autoscaling in GB"
  type        = number
  default     = 50
}

# --- DNS ---

variable "hosted_zone_name" {
  description = "Route53 hosted zone name"
  type        = string
  default     = "aws.lacloaca.com"
}

variable "app_domain" {
  description = "FQDN for the application Ingress"
  type        = string
  default     = "api-mx.aws.lacloaca.com"
}
