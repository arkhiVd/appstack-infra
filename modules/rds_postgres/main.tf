# =============================================================================
# RDS PostgreSQL Module
# Single-AZ db.t3.micro, 20 GiB gp3 — fits 12-month free tier.
# Private subnets only, no public access, ingress from ECS SG only.
# Primary store. User searches NEVER hit this directly (OpenSearch serves
# search); price updates publish to SQS -> sync worker -> OpenSearch.
# =============================================================================

resource "aws_db_subnet_group" "this" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = var.subnet_ids

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

resource "aws_db_instance" "this" {
  identifier     = "${var.project_name}-postgres"
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  allocated_storage     = var.allocated_storage
  max_allocated_storage = 0 # disable storage autoscaling (cost guard)
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.vpc_security_group_id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period = var.backup_retention_period
  skip_final_snapshot     = true # dev: clean destroy
  deletion_protection     = false
  apply_immediately       = true

  # Logical replication enabled — supports future Debezium/CDC if the
  # SQS-based sync is later swapped for change-data-capture streaming.
  parameter_group_name = aws_db_parameter_group.this.name

  tags = {
    Name = "${var.project_name}-postgres"
  }
}

resource "aws_db_parameter_group" "this" {
  name   = "${var.project_name}-pg16"
  family = "postgres16"

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  tags = {
    Name = "${var.project_name}-pg16"
  }
}
