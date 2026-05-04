module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 10)]
  database_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 20)]

  enable_nat_gateway     = true
  single_nat_gateway     = true # cost-cutting for the demo
  one_nat_gateway_per_az = false
  enable_dns_hostnames   = true
  enable_dns_support     = true

  create_database_subnet_group = true

  # VPC flow logs to CloudWatch — required by the report's network-security section.
  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_max_aggregation_interval               = 60
  flow_log_cloudwatch_log_group_retention_in_days = 7

  public_subnet_tags = {
    "kubernetes.io/role/elb"                        = "1"
    "kubernetes.io/cluster/${local.cluster_name}"   = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"               = "1"
    "kubernetes.io/cluster/${local.cluster_name}"   = "shared"
  }
}
