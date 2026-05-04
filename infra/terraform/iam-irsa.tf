# IRSA roles — least-privilege IAM bound to specific Kubernetes ServiceAccounts.

# 1) App role: read the single application secret.
data "aws_iam_policy_document" "app_secret_read" {
  statement {
    sid     = "AppSecretRead"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_secretsmanager_secret.app.arn]
  }
  statement {
    sid     = "DecryptCMK"
    actions = ["kms:Decrypt"]
    resources = [aws_kms_key.main.arn]
  }
}

resource "aws_iam_policy" "app_secret_read" {
  name   = "${var.project_name}-app-secret-read"
  policy = data.aws_iam_policy_document.app_secret_read.json
}

module "app_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name     = "${var.project_name}-app"
  role_policy_arns = {
    secret_read = aws_iam_policy.app_secret_read.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${local.app_namespace}:musclequant-app"]
    }
  }
}

# 2) External Secrets Operator role: read any secret with the project prefix.
data "aws_iam_policy_document" "eso" {
  statement {
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecrets",
    ]
    resources = ["arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:${var.project_name}/*"]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.main.arn]
  }
}

resource "aws_iam_policy" "eso" {
  name   = "${var.project_name}-eso"
  policy = data.aws_iam_policy_document.eso.json
}

module "eso_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name = "${var.project_name}-eso"
  role_policy_arns = {
    eso = aws_iam_policy.eso.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
}

# 3) AWS Load Balancer Controller role: managed policy from the official module.
module "lb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name                              = "${var.project_name}-lbc"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}
