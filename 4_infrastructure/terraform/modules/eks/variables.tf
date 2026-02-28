variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.35"
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for EKS (private subnets)"
  type        = list(string)
}

variable "kms_key_arn" {
  description = "KMS key ARN for secrets encryption"
  type        = string
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the EKS API server public endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# System node group — runs cluster components (CoreDNS, ALB Controller, ESO, EBS CSI)
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

# Application node group — runs business workloads (payment-latency-api)
variable "app_node_instance_types" {
  description = "EC2 instance types for application node group"
  type        = list(string)
  default     = ["m6i.large"]
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
  default     = 3
}

variable "hosted_zone_arns" {
  description = "Route53 hosted zone ARNs that external-dns is allowed to manage"
  type        = list(string)
  default     = ["arn:aws:route53:::hostedzone/*"]
}

variable "secrets_manager_arns" {
  description = "ARNs of Secrets Manager secrets for IRSA"
  type        = list(string)
  default     = ["arn:aws:secretsmanager:*:*:secret:production/*"]
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}
