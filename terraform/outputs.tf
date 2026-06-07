output "cluster_name" {
  description = "생성된 GKE 클러스터 이름."
  value       = google_container_cluster.primary.name
}

output "location" {
  description = "클러스터 존."
  value       = google_container_cluster.primary.location
}

output "project_id" {
  description = "프로젝트 ID."
  value       = var.project_id
}

output "get_credentials_command" {
  description = "kubeconfig 등록 명령. up.sh 가 자동 실행하지만 수동 실행도 가능."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --zone ${google_container_cluster.primary.location} --project ${var.project_id}"
}
