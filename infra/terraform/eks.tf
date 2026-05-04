module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = local.cluster_name
  cluster_version = var.kubernetes_version

  # Endpoint: public access ON for the demo (so we can run kubectl from the laptop),
  # but every workload runs in private subnets. For production, set this to false
  # and use a bastion or VPN.
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  # Envelope-encrypt Kubernetes Secrets with a CMK (Phase 6 — data security).
  cluster_encryption_config = {
    provider_key_arn = aws_kms_key.main.arn
    resources        = ["secrets"]
  }

  # Pull CloudWatch + audit logs from the control plane.
  cluster_enabled_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]
  cloudwatch_log_group_retention_in_days = 7
  cloudwatch_log_group_kms_key_id        = aws_kms_key.main.arn

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  # API auth: grant the running terraform principal cluster-admin so we can deploy add-ons.
  enable_cluster_creator_admin_permissions = true
  authentication_mode                      = "API_AND_CONFIG_MAP"

  cluster_addons = {
    coredns                = { most_recent = true }
    kube-proxy             = { most_recent = true }
    vpc-cni                = { most_recent = true }
    eks-pod-identity-agent = { most_recent = true }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  eks_managed_node_group_defaults = {
    ami_type       = "AL2023_x86_64_STANDARD"
    instance_types = var.node_instance_types

    # Phase 7 — block IMDSv1, force IMDSv2 with hop limit 1 so pods can't hop to it.
    metadata_options = {
      http_endpoint               = "enabled"
      http_tokens                 = "required"
      http_put_response_hop_limit = 1
      instance_metadata_tags      = "disabled"
    }

    block_device_mappings = {
      xvda = {
        device_name = "/dev/xvda"
        ebs = {
          volume_size           = 30
          volume_type           = "gp3"
          encrypted             = true
          kms_key_id            = aws_kms_key.main.arn
          delete_on_termination = true
        }
      }
    }
  }

  eks_managed_node_groups = {
    default = {
      desired_size = var.node_desired_size
      min_size     = var.node_min_size
      max_size     = var.node_max_size
      labels = {
        "workload" = "general"
      }
    }
  }
}

# IRSA role for the EBS CSI driver (referenced above).
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name             = "${var.project_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}
