variable "region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Nome do cluster EKS"
  type        = string
  default     = "toggle-cluster"
}

variable "argocd_chart_version" {
  description = "Versão do Helm Chart do Argo CD"
  type        = string
  default     = "10.15.0"
}

variable "service_type" {
  description = "Tipo de serviço Kubernetes"
  type        = string
  default     = "LoadBalancer"
}

variable "vpc_id" {
  description = "ID do VPC"
  type        = string
}