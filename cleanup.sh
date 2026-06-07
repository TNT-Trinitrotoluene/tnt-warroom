#!/usr/bin/env bash
# =====================================================================
# cleanup.sh — 완전 초기화
#   1) down.sh 로 클라우드 리소스 제거 (반드시 먼저!)
#   2) 로컬 Terraform 상태/캐시/렌더링 파일 삭제
#   3) (옵션) --docker : 사용하지 않는 docker 볼륨 prune
#
# ⚠️ 주의: 이 랩은 GKE(원격)에서 돌기 때문에 "랩 전용 docker 볼륨"은 없다.
#    --docker 는 시스템의 '모든' dangling 볼륨을 지우므로(다른 kind 클러스터 등
#    영향 가능) 기본적으로 실행하지 않는다. 정말 필요할 때만 직접 붙여라.
# =====================================================================
set -uo pipefail
cd "$(dirname "$0")"

log()  { echo -e "\033[1;36m[cleanup]\033[0m $*"; }
warn() { echo -e "\033[1;33m[cleanup]\033[0m $*"; }

DO_DOCKER=false
for a in "$@"; do
  case "$a" in
    --docker) DO_DOCKER=true ;;
    *) warn "알 수 없는 옵션: $a" ;;
  esac
done

log "1/3 클라우드 리소스 삭제 (down.sh) ..."
./down.sh || warn "down.sh 가 일부 실패했을 수 있다 — 상태를 확인하라."

log "2/3 로컬 Terraform 상태/캐시/렌더링 삭제 ..."
rm -rf terraform/.terraform terraform/.terraform.lock.hcl
rm -f  terraform/terraform.tfstate terraform/terraform.tfstate.backup
rm -f  terraform/*.tfplan
rm -rf rendered/

if $DO_DOCKER; then
  if command -v docker >/dev/null; then
    warn "3/3 docker volume prune 실행 (시스템 전체의 미사용 볼륨 삭제) ..."
    docker volume prune -f || true
  else
    warn "docker 가 없어 prune 생략."
  fi
else
  log "3/3 docker prune 생략 (GKE 랩은 로컬 볼륨 없음). 필요 시: ./cleanup.sh --docker"
fi

cat <<EOF

============================================================
✅ 초기화 완료.

⚠️ 클라우드에 리소스가 남아있지 않은지 마지막으로 확인 권장:
  gcloud container clusters list --project "${GCP_PROJECT_ID:-tih-testproject}"
============================================================
EOF
