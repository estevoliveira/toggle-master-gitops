variable "cluster_name" {
  description = "Nome do cluster EKS"
  type        = string
  default     = "toggle-cluster"
}

variable "region" {
  description = "Região da AWS"
  type        = string
  default     = "us-east-1"
}

variable "vpc_id" {
  description = "ID do VPC"
  type        = string
}