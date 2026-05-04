variable "project_name" {
  type        = string
  description = "Lowercase project prefix used for naming all resources."
  default     = "musclequant"
}

variable "region" {
  type        = string
  description = "AWS region."
  default     = "us-east-1"
}

variable "kubernetes_version" {
  type        = string
  description = "EKS Kubernetes version."
  default     = "1.30"
}

variable "node_instance_types" {
  type        = list(string)
  description = "EC2 instance types for the EKS managed node group."
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 3
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "db_username" {
  type    = string
  default = "musclequant"
}

variable "db_name" {
  type    = string
  default = "musclequant"
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "tags" {
  type = map(string)
  default = {
    Project    = "musclequant"
    ManagedBy  = "terraform"
    Compliance = "cs581-signature"
  }
}
