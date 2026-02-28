# RDS Module - PostgreSQL Multi-AZ with encryption
# Source: terraform-aws-modules/rds/aws (https://registry.terraform.io/modules/terraform-aws-modules/rds/aws)

module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.0"

  identifier = var.identifier

  engine               = "postgres"
  engine_version       = var.engine_version
  family               = "postgres17"
  major_engine_version = "17"
  instance_class       = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage

  db_name  = var.db_name
  username = var.db_username
  port     = 5432

  # Use Secrets Manager for master password
  manage_master_user_password = true

  # Multi-AZ for high availability
  multi_az = true

  # Network
  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # Encryption at rest with KMS
  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  # Backup
  backup_retention_period = var.backup_retention_period
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  # Performance Insights
  performance_insights_enabled    = true
  performance_insights_kms_key_id = var.kms_key_arn

  # Deletion protection
  deletion_protection              = true
  skip_final_snapshot              = false
  final_snapshot_identifier_prefix = "${var.identifier}-final"

  # Enhanced monitoring
  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  # Parameters
  parameters = [
    {
      name  = "log_connections"
      value = "1"
    },
    {
      name  = "log_disconnections"
      value = "1"
    },
  ]

  tags = merge(var.tags, {
    Module = "rds"
  })
}

# Security group for RDS - rules managed via separate aws_security_group_rule
# to avoid inline vs standalone drift when RDS Proxy adds its own rule.
resource "aws_security_group" "rds" {
  name_prefix = "${var.identifier}-rds-"
  description = "Security group for RDS PostgreSQL"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.identifier}-rds"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "rds_from_eks" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = var.eks_security_group_ids[0]
  description              = "PostgreSQL from EKS"
}

# IAM role for enhanced monitoring
resource "aws_iam_role" "rds_monitoring" {
  name_prefix = "${var.identifier}-rds-monitoring-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "monitoring.rds.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# --- RDS Proxy (connection pooling for low-latency) ---

resource "aws_db_proxy" "this" {
  count = var.rds_proxy_enabled ? 1 : 0

  name                   = "${var.identifier}-proxy"
  engine_family          = "POSTGRESQL"
  role_arn               = aws_iam_role.rds_proxy[0].arn
  vpc_security_group_ids = [aws_security_group.rds_proxy[0].id]
  vpc_subnet_ids         = var.private_subnet_ids

  require_tls         = true
  idle_client_timeout = 1800
  debug_logging       = false

  auth {
    auth_scheme = "SECRETS"
    iam_auth    = "DISABLED"
    secret_arn  = module.rds.db_instance_master_user_secret_arn
  }

  tags = merge(var.tags, {
    Name = "${var.identifier}-proxy"
  })
}

resource "aws_db_proxy_default_target_group" "this" {
  count = var.rds_proxy_enabled ? 1 : 0

  db_proxy_name = aws_db_proxy.this[0].name

  connection_pool_config {
    max_connections_percent      = 100
    max_idle_connections_percent = 50
    connection_borrow_timeout    = 120
  }
}

resource "aws_db_proxy_target" "this" {
  count = var.rds_proxy_enabled ? 1 : 0

  db_proxy_name          = aws_db_proxy.this[0].name
  target_group_name      = aws_db_proxy_default_target_group.this[0].name
  db_instance_identifier = module.rds.db_instance_identifier
}

# Security group for RDS Proxy — EKS pods connect here instead of directly to RDS
resource "aws_security_group" "rds_proxy" {
  count = var.rds_proxy_enabled ? 1 : 0

  name_prefix = "${var.identifier}-rds-proxy-"
  description = "Security group for RDS Proxy"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = var.eks_security_group_ids
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.identifier}-rds-proxy"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Allow RDS to accept connections from the proxy (separate rule to avoid cycle)
resource "aws_security_group_rule" "rds_from_proxy" {
  count = var.rds_proxy_enabled ? 1 : 0

  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.rds_proxy[0].id
  description              = "PostgreSQL from RDS Proxy"
}

# IAM role for RDS Proxy to read the master secret from Secrets Manager
resource "aws_iam_role" "rds_proxy" {
  count = var.rds_proxy_enabled ? 1 : 0

  name_prefix = "${var.identifier}-rds-proxy-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "rds_proxy" {
  count = var.rds_proxy_enabled ? 1 : 0

  name = "secrets-manager-access"
  role = aws_iam_role.rds_proxy[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:GetResourcePolicy",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds"
        ]
        Resource = module.rds.db_instance_master_user_secret_arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = var.kms_key_arn
      }
    ]
  })
}
