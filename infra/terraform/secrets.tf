# Store the DB credentials and connection URL in Secrets Manager.
# External Secrets Operator will sync this into a K8s Secret using IRSA.

resource "aws_secretsmanager_secret" "app" {
  name                    = "${var.project_name}/app"
  description             = "Application secrets for MuscleQuant API."
  kms_key_id              = aws_kms_key.main.arn
  recovery_window_in_days = 0
}

resource "random_password" "flask_secret" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({
    DATABASE_URL = "postgresql+psycopg2://${var.db_username}:${urlencode(random_password.db.result)}@${module.rds.db_instance_address}:5432/${var.db_name}?sslmode=require"
    SECRET_KEY   = random_password.flask_secret.result
  })
}
