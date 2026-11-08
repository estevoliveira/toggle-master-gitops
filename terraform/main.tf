module "alb" {
  source       = "./alb"
  cluster_name = var.cluster_name
  region       = var.region
  vpc_id       = var.vpc_id
}

module "argocd" {
  source               = "./argocd"
  cluster_name         = var.cluster_name
  service_type         = var.service_type
  argocd_chart_version = var.argocd_chart_version

  depends_on = [
    module.alb
  ]
}