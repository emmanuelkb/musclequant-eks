output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "ecr_api_repo_url" {
  value = aws_ecr_repository.api.repository_url
}

output "ecr_report_gen_repo_url" {
  value = aws_ecr_repository.report_gen.repository_url
}

output "ecr_registry" {
  value = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "rds_endpoint" {
  value = module.rds.db_instance_address
}

output "app_secret_arn" {
  value = aws_secretsmanager_secret.app.arn
}

output "app_irsa_role_arn" {
  value = module.app_irsa.iam_role_arn
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "guardduty_detector_id" {
  value = aws_guardduty_detector.this.id
}

# Convenience: emit the values the K8s manifests need to be templated with.
output "manifest_substitutions" {
  value = {
    AWS_REGION       = var.region
    APP_NAMESPACE    = local.app_namespace
    APP_IRSA_ROLE    = module.app_irsa.iam_role_arn
    APP_SECRET_NAME  = aws_secretsmanager_secret.app.name
    ECR_REGISTRY     = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"
    ECR_API_REPO     = aws_ecr_repository.api.repository_url
    ECR_REPORT_REPO  = aws_ecr_repository.report_gen.repository_url
    CLUSTER_NAME     = module.eks.cluster_name
  }
}
