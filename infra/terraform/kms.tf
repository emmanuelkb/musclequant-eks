data "aws_iam_policy_document" "kms_main" {
  statement {
    sid       = "EnableRootPermissions"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }

  # CloudWatch Logs needs to use this CMK to encrypt the EKS log group.
  statement {
    sid = "AllowCloudWatchLogs"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${var.region}:${local.account_id}:log-group:*"]
    }
  }

  # AWS services (EC2/EBS, RDS, Secrets Manager, ECR) that act on resources we
  # configure to use this CMK. Without this block, EBS-backed ASG instances
  # fail at boot with Client.InvalidKMSKey.InvalidState.
  statement {
    sid = "AllowAWSServicesUseOfCMK"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]
    principals {
      type = "Service"
      identifiers = [
        "rds.amazonaws.com",
        "secretsmanager.amazonaws.com",
        "ec2.amazonaws.com",
        "ecr.amazonaws.com",
      ]
    }
  }

  # Allow AWS principals to create grants on the key for resource encryption
  # (standard CMK pattern — required for ASG → EBS, RDS automated snapshots,
  # Secrets Manager rotation, etc.). Scoped by the GrantIsForAWSResource
  # condition so only AWS service-linked roles can claim it.
  statement {
    sid       = "AllowAttachmentOfPersistentResources"
    actions   = ["kms:CreateGrant"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }

  # Explicit grants to the AutoScaling service-linked role. The wildcard
  # pattern above is not always sufficient for ASG → EBS encryption; AWS
  # surfaces the failure as Client.InvalidKMSKey.InvalidState. Naming the SLR
  # by ARN matches AWS's canonical CMK template and is what makes EBS-backed
  # node groups boot.
  statement {
    sid = "AllowASGSLRUseOfCMK"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"]
    }
  }

  statement {
    sid       = "AllowASGSLRCreateGrant"
    actions   = ["kms:CreateGrant"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"]
    }
    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }
}

resource "aws_kms_key" "main" {
  description             = "${var.project_name} multi-purpose CMK (EKS secrets, EBS, RDS, logs)"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms_main.json
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.project_name}-main"
  target_key_id = aws_kms_key.main.key_id
}
