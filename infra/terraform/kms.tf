resource "aws_kms_key" "main" {
  description             = "${var.project_name} multi-purpose CMK (EKS secrets, EBS, RDS, logs)"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.project_name}-main"
  target_key_id = aws_kms_key.main.key_id
}
