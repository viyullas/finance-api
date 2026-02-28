# Mexico Environment - us-east-1 (proxy region, Ley Federal MX)
# AWS no tiene region en Mexico, se usa us-east-1 con etiquetado de datos

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    bucket  = "aabella-terraform-backends"
    key     = "mexico/terraform.tfstate"
    region  = "eu-south-2" # Bucket compartido en eu-south-2, no admite variables
    encrypt = true
    profile = "default"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment   = var.environment
      Region        = var.region_name
      ManagedBy     = "terraform"
      DataResidency = var.data_residency
      Compliance    = var.compliance
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  name         = var.project_name
  cluster_name = "${local.name}-eks"
  region       = data.aws_region.current.name

  tags = {
    Project       = "payment-latency-api"
    Environment   = var.environment
    Region        = var.region_name
    DataResidency = var.data_residency
    Compliance    = var.compliance
  }
}

# KMS key for encryption
resource "aws_kms_key" "main" {
  description             = "KMS key for ${local.name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccountFullAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudTrailEncryption"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action = [
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceArn" = "arn:aws:cloudtrail:${local.region}:${local.account_id}:trail/${local.name}-trail"
          }
        }
      }
    ]
  })

  tags = local.tags
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.main.key_id
}

# CloudTrail for auditing
resource "aws_cloudtrail" "main" {
  name                          = "${local.name}-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true
  is_multi_region_trail         = false
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.main.arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  tags = local.tags
}

resource "aws_s3_bucket" "cloudtrail" {
  bucket        = "${local.name}-cloudtrail-logs"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail.arn
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

# VPC
module "vpc" {
  source = "../../modules/vpc"

  name         = local.name
  cidr         = var.vpc_cidr
  cluster_name = local.cluster_name

  azs              = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets  = var.private_subnets
  public_subnets   = var.public_subnets
  database_subnets = var.database_subnets

  single_nat_gateway = var.single_nat_gateway

  tags = local.tags
}

# EKS
module "eks" {
  source = "../../modules/eks"

  cluster_name = local.cluster_name
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = module.vpc.private_subnets
  kms_key_arn  = aws_kms_key.main.arn

  cluster_endpoint_public_access_cidrs = var.argocd_source_cidr != "" ? concat(var.cluster_endpoint_public_access_cidrs, ["${var.argocd_source_cidr}/32"]) : var.cluster_endpoint_public_access_cidrs

  # System node group: cluster components (CoreDNS, ALB Controller, ESO)
  system_node_instance_types = var.system_node_instance_types
  system_node_min_size       = var.system_node_min_size
  system_node_max_size       = var.system_node_max_size
  system_node_desired_size   = var.system_node_desired_size

  # Application node group: business workloads
  app_node_instance_types = var.app_node_instance_types
  app_node_min_size       = var.app_node_min_size
  app_node_max_size       = var.app_node_max_size
  app_node_desired_size   = var.app_node_desired_size

  secrets_manager_arns = [
    "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:production/${var.region_name}/*",
    "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:rds!db-*"
  ]

  hosted_zone_arns = [data.aws_route53_zone.main.arn]

  tags = local.tags
}

# RDS
module "rds" {
  source = "../../modules/rds"

  identifier             = "${local.name}-payments"
  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_id                 = module.vpc.vpc_id
  eks_security_group_ids = [module.eks.node_security_group_id]
  kms_key_arn            = aws_kms_key.main.arn

  instance_class        = var.rds_instance_class
  allocated_storage     = var.rds_allocated_storage
  max_allocated_storage = var.rds_max_allocated_storage

  rds_proxy_enabled  = var.rds_proxy_enabled
  private_subnet_ids = module.vpc.private_subnets

  tags = local.tags
}

# ACM certificate + DNS validation
data "aws_route53_zone" "main" {
  name = var.hosted_zone_name
}

resource "aws_acm_certificate" "app" {
  domain_name       = var.app_domain
  validation_method = "DNS"
  tags              = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.app.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = data.aws_route53_zone.main.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 300
}

resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation : record.fqdn]
}

# ECR repository for container images
resource "aws_ecr_repository" "app" {
  name                 = "payment-latency-api"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.main.arn
  }

  tags = local.tags
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "1", "2", "3"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Remove untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# Random suffix to avoid Secrets Manager name collisions on destroy/recreate cycles
resource "random_id" "secret_suffix" {
  byte_length = 4
}

# Store API secret key in Secrets Manager (DB credentials managed by RDS directly)
resource "aws_secretsmanager_secret" "app_secrets" {
  name                    = "${var.environment}/${var.region_name}/payment-latency-api-${random_id.secret_suffix.hex}"
  kms_key_id              = aws_kms_key.main.arn
  recovery_window_in_days = 0
  tags                    = local.tags
}
