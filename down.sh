#!/usr/bin/env bash
# =====================================================================
# down.sh — 환경 전체 삭제 (Terraform destroy 로 GKE 클러스터까지 제거)
# 클러스터를 지우면 그 안의 모든 리소스도 함께 사라진다.
# =====================================================================
set -uo pipefail
cd "$(dirname "$0")"

log()  { echo -e "\033[1;36m[down]\033[0m $*"; }
warn() { echo -e "\033[1;33m[down]\033[0m $*"; }

if [ -f .env ]; then set -a; . ./.env; set +a; fi

PROJECT="${GCP_PROJECT_ID:-tih-testproject}"
REGION="${GCP_REGION:-asia-northeast3}"
ZONE="${GCP_ZONE:-asia-northeast3-a}"
CLUSTER="${CLUSTER_NAME:-tnt-warroom}"

export TF_VAR_project_id="$PROJECT"
export TF_VAR_region="$REGION"
export TF_VAR_zone="$ZONE"
export TF_VAR_cluster_name="$CLUSTER"
[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && export TF_VAR_gcp_credentials_file="$GOOGLE_APPLICATION_CREDENTIALS"

# (선택) 클러스터가 아직 살아있고 reachable 하면 워크로드 먼저 정리 — 깔끔한 finalizer 처리를 위해.
CTX="gke_${PROJECT}_${ZONE}_${CLUSTER}"
if kubectl --context "$CTX" get ns >/dev/null 2>&1; then
  log "인-클러스터 리소스 정리 ..."
  kubectl --context "$CTX" delete -k gitops/ --ignore-not-found --wait=false 2>/dev/null || true
  kubectl --context "$CTX" -n monitoring delete secret slack-webhooks --ignore-not-found 2>/dev/null || true
fi

log "Terraform destroy — GKE 클러스터/노드풀/VPC 삭제 (수 분 소요) ..."
terraform -chdir=terraform destroy -input=false -auto-approve

# 로컬 kube 컨텍스트 정리 (best-effort)
kubectl config delete-context "$CTX"  >/dev/null 2>&1 || true
kubectl config delete-cluster "$CTX"  >/dev/null 2>&1 || true

cat <<EOF

============================================================
✅ 삭제 완료. GKE 클러스터/노드/VPC 가 제거되어 과금이 멈춘다.

로컬 Terraform 상태/캐시까지 비우려면:
  ./cleanup.sh
============================================================
EOF
