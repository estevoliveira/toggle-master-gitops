
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"

  namespace        = "argocd"
  create_namespace = true

  version = var.argocd_chart_version

  values = [
    yamlencode({
      server = {
        service = {
          type = var.service_type
        }
      }
    })
  ]

  wait    = true
  timeout = 600
}