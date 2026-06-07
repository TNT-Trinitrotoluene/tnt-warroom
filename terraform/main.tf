# =====================================================================
# 플랫폼 계층(IaC) — GKE Standard 클러스터 + VPC + 노드풀.
# 인-클러스터 리소스(앱/모니터링/부하/알림)는 gitops/ 의 Kustomize 가 담당한다.
# (의도적 분리: 모니터링 스택의 CRD/순서 의존성을 Terraform 으로 다루면 깨지기 쉬우므로
#  ArgoCD 가 동기화하기 좋은 형태의 선언형 YAML 로 분리했다.)
# =====================================================================

# ── 1. 필요한 API 활성화 ──
resource "google_project_service" "container" {
  project            = var.project_id
  service            = "container.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "compute" {
  project            = var.project_id
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

# ── 2. VPC + 서브넷 (VPC-native 용 secondary range 포함) ──
resource "google_compute_network" "vpc" {
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.compute]
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.cluster_name}-subnet"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = "10.128.0.0/20"

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.132.0.0/14"
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.136.0.0/20"
  }
}

# ── 3. GKE Standard 클러스터 (zonal) ──
resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.zone

  # 기본 노드풀은 제거하고 별도 관리형 노드풀을 붙인다(권장 패턴).
  remove_default_node_pool = true
  initial_node_count       = 1

  networking_mode = "VPC_NATIVE"
  network         = google_compute_network.vpc.id
  subnetwork      = google_compute_subnetwork.subnet.id

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  release_channel {
    channel = var.release_channel
  }

  # down.sh / terraform destroy 가 막히지 않도록 보호 해제(학습용).
  deletion_protection = false

  depends_on = [
    google_project_service.container,
    google_compute_subnetwork.subnet,
  ]
}

# ── 4. 노드풀 (Spot, 소형) ──
resource "google_container_node_pool" "primary_nodes" {
  name       = "${var.cluster_name}-pool"
  location   = var.zone
  cluster    = google_container_cluster.primary.name
  node_count = var.node_count

  node_config {
    machine_type = var.machine_type
    disk_size_gb = var.disk_size_gb
    disk_type    = "pd-standard"
    spot         = var.use_spot

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    labels = {
      lab = "tnt-sre-warroom"
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
