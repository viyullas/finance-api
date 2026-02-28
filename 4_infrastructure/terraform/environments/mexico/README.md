# Mexico Environment — us-east-1 (Ley Federal MX)

Deploys the complete payment platform infrastructure for Mexico. AWS has no region in Mexico; `us-east-1` (Virginia) is used as proxy region with exhaustive data residency tagging (`DataResidency=MX`, `Compliance=LeyFederalMX`) to comply with the Ley Federal de Protección de Datos Personales.

## Architecture

```
us-east-1
├── VPC (10.20.0.0/16, 3 AZs)
│   ├── Public subnets    — ALB, NAT Gateway
│   ├── Private subnets   — EKS nodes
│   └── Database subnets  — RDS (no internet access)
├── EKS (managed, v1.30)
│   ├── system node group  — CoreDNS, ALB Controller, ESO (t3.medium, fixed size)
│   └── app node group     — payment-latency-api (t3.medium, autoscaling 2–6)
├── RDS PostgreSQL 17 (Multi-AZ, encrypted, managed password)
│   └── RDS Proxy          — connection pooling (~30-50ms saved per request)
├── KMS key                — encrypts RDS, EBS, S3, K8s secrets
├── CloudTrail             — API audit trail, logs in S3 with KMS
├── ECR                    — container image registry
├── ACM certificate        — TLS for api-mx.aws.lacloaca.com
└── Secrets Manager        — API_SECRET_KEY storage
```

## State Backend

S3 bucket `aabella-terraform-backends`, key `mexico/terraform.tfstate`, region `eu-south-2` (shared bucket).
Locking via native S3 conditional writes (Terraform >= 1.10, no DynamoDB required).

### ArgoCD connectivity note

ArgoCD runs in the Spain cluster and manages Mexico remotely. The Mexico EKS API endpoint is restricted by IP (`cluster_endpoint_public_access_cidrs`). The Spain NAT Gateway IP is passed automatically by `make tf-mexico` via the `argocd_source_cidr` variable and appended to the allowlist.

---

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.10.0 |
| aws | ~> 5.0 |
| random | ~> 3.0 |

## Providers

| Name | Version |
|------|---------|
| [hashicorp/aws](https://registry.terraform.io/providers/hashicorp/aws/latest) | ~> 5.0 |
| [hashicorp/random](https://registry.terraform.io/providers/hashicorp/random/latest) | ~> 3.0 |

---

## Modules

| Name | Source | Version | Description |
|------|--------|---------|-------------|
| vpc | [terraform-aws-modules/vpc/aws](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws) | ~> 5.0 | Multi-AZ VPC with public, private and database subnet tiers |
| eks | [terraform-aws-modules/eks/aws](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws) | ~> 20.0 | Managed EKS cluster with two node groups (system + application) |
| rds | [terraform-aws-modules/rds/aws](https://registry.terraform.io/modules/terraform-aws-modules/rds/aws) | ~> 6.0 | PostgreSQL 17 Multi-AZ with managed password and optional RDS Proxy |
| iam (×4 IRSA roles) | [terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks](https://registry.terraform.io/modules/terraform-aws-modules/iam/aws/latest/submodules/iam-role-for-service-accounts-eks) | ~> 5.0 | IRSA roles for ESO, ALB Controller, EBS CSI Driver and external-dns |

---

## Resources

| Name | Type |
|------|------|
| aws_kms_key.main | resource |
| aws_kms_alias.main | resource |
| aws_cloudtrail.main | resource |
| aws_s3_bucket.cloudtrail | resource |
| aws_s3_bucket_server_side_encryption_configuration.cloudtrail | resource |
| aws_s3_bucket_policy.cloudtrail | resource |
| aws_acm_certificate.app | resource |
| aws_route53_record.acm_validation | resource |
| aws_acm_certificate_validation.app | resource |
| aws_ecr_repository.app | resource |
| aws_ecr_lifecycle_policy.app | resource |
| aws_secretsmanager_secret.app_secrets | resource |
| random_id.secret_suffix | resource |
| aws_caller_identity.current | data source |
| aws_region.current | data source |
| aws_availability_zones.available | data source |
| aws_route53_zone.main | data source |

---

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| aws_region | AWS region for this environment | `string` | `"us-east-1"` | no |
| project_name | Project name prefix for all resources | `string` | `"pluxee-mexico"` | no |
| environment | Environment name | `string` | `"production"` | no |
| region_name | Human-readable region identifier | `string` | `"mexico"` | no |
| data_residency | Data residency classification (EU, MX, etc.) | `string` | `"MX"` | no |
| compliance | Compliance framework | `string` | `"LeyFederalMX"` | no |
| vpc_cidr | CIDR block for the VPC | `string` | `"10.20.0.0/16"` | no |
| private_subnets | Private subnet CIDR blocks | `list(string)` | `["10.20.1.0/24", "10.20.2.0/24", "10.20.3.0/24"]` | no |
| public_subnets | Public subnet CIDR blocks | `list(string)` | `["10.20.11.0/24", "10.20.12.0/24", "10.20.13.0/24"]` | no |
| database_subnets | Database subnet CIDR blocks | `list(string)` | `["10.20.21.0/24", "10.20.22.0/24", "10.20.23.0/24"]` | no |
| single_nat_gateway | Use a single NAT Gateway instead of one per AZ | `bool` | `true` | no |
| cluster_endpoint_public_access_cidrs | CIDRs allowed to reach the EKS API server public endpoint | `list(string)` | `["83.33.97.233/32"]` | no |
| argocd_source_cidr | Additional CIDR (Spain NAT Gateway IP) added to EKS endpoint allowlist so ArgoCD server can reach Mexico cluster. Passed automatically by the Makefile after Spain is deployed. | `string` | `""` | no |
| system_node_instance_types | EC2 instance types for system node group | `list(string)` | `["t3.medium"]` | no |
| system_node_min_size | Minimum number of system nodes | `number` | `2` | no |
| system_node_max_size | Maximum number of system nodes | `number` | `3` | no |
| system_node_desired_size | Desired number of system nodes | `number` | `2` | no |
| app_node_instance_types | EC2 instance types for application node group | `list(string)` | `["t3.medium"]` | no |
| app_node_min_size | Minimum number of application nodes | `number` | `2` | no |
| app_node_max_size | Maximum number of application nodes | `number` | `6` | no |
| app_node_desired_size | Desired number of application nodes | `number` | `2` | no |
| rds_proxy_enabled | Enable RDS Proxy for connection pooling | `bool` | `true` | no |
| rds_instance_class | RDS instance class | `string` | `"db.t4g.micro"` | no |
| rds_allocated_storage | RDS allocated storage in GB | `number` | `20` | no |
| rds_max_allocated_storage | RDS max allocated storage for autoscaling in GB | `number` | `50` | no |
| hosted_zone_name | Route53 hosted zone name | `string` | `"aws.lacloaca.com"` | no |
| app_domain | FQDN for the application Ingress | `string` | `"api-mx.aws.lacloaca.com"` | no |

---

## Outputs

| Name | Description |
|------|-------------|
| vpc_id | VPC ID |
| eks_cluster_name | EKS cluster name |
| eks_cluster_endpoint | EKS cluster endpoint |
| rds_endpoint | RDS instance endpoint |
| kms_key_arn | KMS key ARN |
| external_secrets_role_arn | IAM role ARN for External Secrets Operator (IRSA) |
| lb_controller_role_arn | IAM role ARN for AWS Load Balancer Controller (IRSA) |
| external_dns_role_arn | IAM role ARN for external-dns (IRSA) |
| account_id | AWS Account ID |
| ecr_registry | ECR registry URL for Helm values (`image.registry`) |
| ecr_repository_url | Full ECR repository URL (`registry/repo`) |
| acm_certificate_arn | ACM certificate ARN for the app Ingress |
| app_domain | Application domain name |
| rds_master_secret_arn | ARN of the RDS-managed master password secret |
| app_secret_id | Secrets Manager secret name for `API_SECRET_KEY` |
| db_connection_endpoint | Database connection endpoint (RDS Proxy if enabled, direct RDS otherwise) |
| nat_public_ip | Public IP of the NAT Gateway (used by ArgoCD server to reach Mexico EKS endpoint) |
