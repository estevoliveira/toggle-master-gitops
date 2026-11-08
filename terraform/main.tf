module "alb"{
    source = "./alb"
    cluster_name = var.cluster_name
}

module "argocd" {
    source = "./argocd"
    cluster_name = var.cluster_name
    service_type = var.service_type
    argocd_chart_version = var.argocd_chart_version

    depends_on = [
        module.alb
    ]
}