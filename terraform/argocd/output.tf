
output "argocd_namespace" {
  description = "Namespace de instalação do Argo CD"
  value       = helm_release.argocd.namespace
}

output "argocd_release_name" {
  description = "Nome da release Helm"
  value       = helm_release.argocd.name
}

output "argocd_chart_version" {
  description = "Versão instalada do Helm Chart"
  value       = helm_release.argocd.version
}

output "argocd_status" {
  description = "Status da instalação do Argo CD"
  value       = helm_release.argocd.status
}