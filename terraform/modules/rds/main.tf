locals {
  name = "${var.project}-${var.environment}"
}

# ── Random password for RDS ───────────────────────────────────────────────────

resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# ── Secrets Manager — stores DB credentials ───────────────────────────────────

resource "aws_secretsmanager_secret" "db" {
  name                    = "${local.name}/rds/credentials"
  description             = "Dagster PostgreSQL credentials"
  recovery_window_in_days = 0

  tags = {
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    host     = aws_db_instance.dagster.address
    port     = aws_db_instance.dagster.port
    dbname   = var.db_name
    url      = "postgresql://${var.db_username}:${random_password.db.result}@${aws_db_instance.dagster.address}:${aws_db_instance.dagster.port}/${var.db_name}"
  })
}

# ── Security Group: RDS ───────────────────────────────────────────────────────

resource "aws_security_group" "rds" {
  name        = "${local.name}-rds-sg"
  description = "Allow PostgreSQL access from EKS nodes only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.eks_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${local.name}-rds-sg"
    Project     = var.project
    Environment = var.environment
  }
}

# ── RDS Subnet Group ──────────────────────────────────────────────────────────

resource "aws_db_subnet_group" "dagster" {
  name        = "${local.name}-dagster-subnet-group"
  subnet_ids  = var.private_subnet_ids
  description = "Subnet group for Dagster PostgreSQL RDS"

  tags = {
    Name        = "${local.name}-dagster-subnet-group"
    Project     = var.project
    Environment = var.environment
  }
}

# ── RDS Parameter Group ───────────────────────────────────────────────────────

resource "aws_db_parameter_group" "dagster" {
  family = "postgres15"
  name   = "${local.name}-dagster-pg15"

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name  = "log_duration"
    value = "0"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000" # Log slow queries > 1 second
  }

  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements"
  }

  tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# ── RDS Instance ──────────────────────────────────────────────────────────────

resource "aws_db_instance" "dagster" {
  identifier = "${local.name}-dagster-postgres"

  engine               = "postgres"
  engine_version       = "15.7"
  instance_class       = var.db_instance_class
  db_name              = var.db_name
  username             = var.db_username
  password             = random_password.db.result
  parameter_group_name = aws_db_parameter_group.dagster.name

  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.dagster.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az            = var.db_multi_az
  publicly_accessible = false
  deletion_protection = false
  skip_final_snapshot = true
  max_allocated_storage = var.db_max_allocated_storage

  backup_retention_period = 7
  maintenance_window      = "sun:04:00-sun:05:00"

  performance_insights_enabled = true
  monitoring_interval          = 60
  monitoring_role_arn          = aws_iam_role.rds_monitoring.arn

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  copy_tags_to_snapshot = true

  # Ignore minor version changes — AWS auto-upgrades patch versions during
  # maintenance windows; we don't want that to trigger a plan diff.
  lifecycle {
    ignore_changes = [engine_version]
  }

  tags = {
    Name        = "${local.name}-dagster-postgres"
    Project     = var.project
    Environment = var.environment
  }
}

# ── IAM Role for RDS Enhanced Monitoring ──────────────────────────────────────

resource "aws_iam_role" "rds_monitoring" {
  name = "${local.name}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
  role       = aws_iam_role.rds_monitoring.name
}
