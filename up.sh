#!/usr/bin/env bash
# =====================================================================
# up.sh — TNT SRE War-Room Lab 환경 기동
#   1) Terraform 으로 GKE 클러스터 생성 (플랫폼 계층)
#   2) kubeconfig 등록
#   3) 네임스페이스 + Slack Secret + 인-클러스터 리소스(Kustomize) 적용
# 사용법: ./up.sh [--with-argocd]
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")"

log()  { echo -e "\033[1;36m[up]\033[0m $*"; }
warn() { echo -e "\033[1;33m[up]\033[0m $*"; }
die()  { echo -e "\033[1;31m[up]\033[0m $*" >&2; exit 1; }

WITH_ARGOCD=false
for a in "$@"; do
  case "$a" in
    --with-argocd) WITH_ARGOCD=true ;;
    *) warn "알 수 없는 옵션: $a" ;;
  esac
done

# ── .env 로드 ──
if [ -f .env ]; then
  set -a; . ./.env; set +a
  log ".env 로드 완료."
else
  warn ".env 없음 → 'cp .env.example .env' 후 값 입력 권장. 기본값으로 진행한다."
fi

# ── 사전 점검 ──
command -v terraform >/dev/null || die "terraform 가 필요하다."
command -v gcloud     >/dev/null || die "gcloud 가 필요하다."
command -v kubectl    >/dev/null || die "kubectl 가 필요하다."

PROJECT="${GCP_PROJECT_ID:-tih-testproject}"
REGION="${GCP_REGION:-asia-northeast3}"
ZONE="${GCP_ZONE:-asia-northeast3-a}"
CLUSTER="${CLUSTER_NAME:-tnt-warroom}"

# ── 인증 점검 ──
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
  [ -f "$GOOGLE_APPLICATION_CREDENTIALS" ] || die "GOOGLE_APPLICATION_CREDENTIALS 경로에 파일이 없다: $GOOGLE_APPLICATION_CREDENTIALS"
  export GOOGLE_APPLICATION_CREDENTIALS
  log "서비스계정 키 사용: $GOOGLE_APPLICATION_CREDENTIALS"
else
  if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
    warn "gcloud ADC 가 설정되지 않았을 수 있다. 실패하면 다음을 먼저 실행하라:"
    warn "  gcloud auth application-default login"
  fi
fi

# ── Terraform 변수 주입 ──
export TF_VAR_project_id="$PROJECT"
export TF_VAR_region="$REGION"
export TF_VAR_zone="$ZONE"
export TF_VAR_cluster_name="$CLUSTER"
[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && export TF_VAR_gcp_credentials_file="$GOOGLE_APPLICATION_CREDENTIALS"

log "1/5 Terraform init & apply — GKE 클러스터 생성 (수 분 소요) ..."
terraform -chdir=terraform init -input=false
terraform -chdir=terraform apply -input=false -auto-approve

log "2/5 kubeconfig 등록 ..."
gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE" --project "$PROJECT"

log "3/5 네임스페이스 적용 ..."
kubectl apply -f gitops/00-namespaces.yaml

log "4/5 Slack 웹훅 Secret(slack-webhooks) 생성/갱신 ..."
kubectl -n monitoring create secret generic slack-webhooks \
  --from-literal=SLACK_WEBHOOK_ALERTS_CRITICAL="${SLACK_WEBHOOK_ALERTS_CRITICAL:-}" \
  --from-literal=SLACK_WEBHOOK_INCIDENT_WAR_ROOM="${SLACK_WEBHOOK_INCIDENT_WAR_ROOM:-}" \
  --from-literal=SLACK_WEBHOOK_ARCHITECTURE_RFC="${SLACK_WEBHOOK_ARCHITECTURE_RFC:-}" \
  --dry-run=client -o yaml | kubectl apply -f -

log "5/5 인-클러스터 리소스 적용 (앱/모니터링/부하) ..."
kubectl apply -k gitops/
# 이미 떠 있던 slack-relay 가 새 Secret 을 읽도록 재기동(있을 때만)
kubectl -n monitoring rollout restart deploy/slack-relay >/dev/null 2>&1 || true

# ── 주요 워크로드 Ready 대기 (실패해도 진행) ──
log "워크로드 Ready 대기 (최대 ~3분, 이미지 풀 포함) ..."
for d in checkout/payment checkout/checkout monitoring/prometheus monitoring/grafana; do
  ns="${d%/*}"; name="${d#*/}"
  kubectl -n "$ns" rollout status "deploy/$name" --timeout=180s || warn "[$d] 아직 Ready 아님 (이미지 풀 지연일 수 있음)"
done

# ── (옵션) ArgoCD ──
if $WITH_ARGOCD; then
  log "(옵션) ArgoCD 설치 ..."
  kubectl get ns argocd >/dev/null 2>&1 || kubectl create ns argocd
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side
  if [ -n "${GITOPS_REPO_URL:-}" ] && command -v envsubst >/dev/null; then
    export GITOPS_REPO_URL GITOPS_REPO_REVISION="${GITOPS_REPO_REVISION:-main}" GITOPS_REPO_PATH="${GITOPS_REPO_PATH:-tnt-sre-warroom/gitops}"
    envsubst < gitops/argocd/application.yaml | kubectl apply -f -
    log "ArgoCD Application 적용 완료."
  else
    warn "GITOPS_REPO_URL 미설정 또는 envsubst 없음 → ArgoCD Application 생략."
  fi
fi

cat <<EOF

============================================================
✅ 환경 기동 완료. 당신은 방금 호출(on-call page)을 받았다.

[접속] 각각 새 터미널에서 port-forward:
  Grafana       :  kubectl -n monitoring port-forward svc/grafana 3000:3000
                   → http://localhost:3000  (대시보드: "TNT Checkout — RED / USE")
  Prometheus    :  kubectl -n monitoring port-forward svc/prometheus 9090:9090
  Alertmanager  :  kubectl -n monitoring port-forward svc/alertmanager 9093:9093

[관찰 시작점]
  kubectl -n checkout get pods -w
  kubectl -n loadgen logs deploy/loadgen -f      # 합성 트래픽의 실시간 성적표

지금부터는 README.md 의 5개 과제를 수행한다.
원인은 알려주지 않는다 — 지표/이벤트/로그로 직접 좁혀라.
막히면 solutions/README.md 를 연다.

⚠️ 실습이 끝나면 비용이 계속 발생하지 않도록 반드시:
  ./down.sh        (클러스터까지 삭제)
============================================================
EOF
