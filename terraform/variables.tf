variable "project_id" {
  description = "GCP 프로젝트 ID. 화면에서 선택한 tih-testproject 가 기본값."
  type        = string
  default     = "tih-testproject"
}

variable "region" {
  description = "GCP 리전."
  type        = string
  default     = "asia-northeast3"
}

variable "zone" {
  description = "Zonal 클러스터가 생성될 존. (비용 절감을 위해 regional 대신 zonal 사용)"
  type        = string
  default     = "asia-northeast3-a"
}

variable "cluster_name" {
  description = "GKE 클러스터 이름."
  type        = string
  default     = "tnt-warroom"
}

variable "machine_type" {
  description = "노드 머신 타입."
  type        = string
  default     = "e2-standard-2"
}

variable "node_count" {
  description = "노드 풀의 노드 수 (zonal 이므로 그대로 총 노드 수)."
  type        = number
  default     = 2
}

variable "use_spot" {
  description = "Spot 노드 사용 여부 (비용 절감). 학습용이므로 기본 true."
  type        = bool
  default     = true
}

variable "disk_size_gb" {
  description = "노드 부트 디스크 크기(GB)."
  type        = number
  default     = 50
}

variable "release_channel" {
  description = "GKE 릴리스 채널."
  type        = string
  default     = "REGULAR"
}

variable "gcp_credentials_file" {
  description = "서비스계정 키 JSON 경로. 비워두면 gcloud ADC / GOOGLE_APPLICATION_CREDENTIALS 를 사용."
  type        = string
  default     = ""
}
