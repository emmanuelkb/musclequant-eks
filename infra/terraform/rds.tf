resource "random_password" "db" {
  length  = 24
  special = true
  # RDS rejects "/", "@", quotes and backslash in master passwords.
  override_special = "!#$%^&*()-_=+[]{}<>:?"
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds"
  description = "Postgres reachable only from the EKS node SG."
  vpc_id      = module.vpc.vpc_id
}

resource "aws_security_group_rule" "rds_from_nodes" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = module.eks.node_security_group_id
  security_group_id        = aws_security_group.rds.id
  description              = "Postgres from EKS workers"
}

resource "aws_security_group_rule" "rds_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.rds.id
}

module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.10"

  identifier = "${var.project_name}-db"

  engine               = "postgres"
  engine_version       = "16.4"
  family               = "postgres16"
  major_engine_version = "16"
  instance_class       = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 50
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.main.arn

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result
  port     = 5432
  manage_master_user_password = false

  multi_az                    = false # cost
  db_subnet_group_name        = module.vpc.database_subnet_group_name
  vpc_security_group_ids      = [aws_security_group.rds.id]
  publicly_accessible         = false
  deletion_protection         = false
  skip_final_snapshot         = true
  backup_retention_period     = 1
  apply_immediately           = true

  # Logs to CloudWatch.
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  performance_insights_enabled    = false

  parameters = [
    { name = "rds.force_ssl", value = "1" }, # TLS in transit
  ]
}
