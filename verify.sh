#!/usr/bin/env bash
# =====================================================================
# verify.sh — 5개 과제의 "완료 기준(Definition of Done)" 점검.
#   * 정답을 채점하는 게 아니라, 산출물이 존재하고 조치가 적용됐는지 확인한다.
#   * 제출물은 tnt-sre-warroom/submissions/*.md 에 직접 작성한다.
#   * 클러스터 상태 점검은 현재 kubeconfig 컨텍스트를 사용한다.
# 출력: 항목별 PASS/FAIL + 마지막 줄 "PASS=n FAIL=m". 모두 통과 시 exit 0.
# =====================================================================
set -uo pipefail
cd "$(dirname "$0")"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo -e "  \033[1;32mPASS\033[0m $*"; }
no() { FAIL=$((FAIL + 1)); echo -e "  \033[1;31mFAIL\033[0m $*"; }

file_ok() { [ -f "$1" ] && [ "$(wc -c < "$1" 2>/dev/null || echo 0)" -ge 200 ]; }

mc() { # cpu quantity → millicores ("500m"→500, "1"→1000, ""→-1)
  python3 - "$1" <<'PY'
import sys
v = (sys.argv[1] or "").strip()
if not v:
    print(-1)
else:
    print(int(float(v[:-1])) if v.endswith("m") else int(float(v) * 1000))
PY
}

CLUSTER_OK=true
kubectl get ns >/dev/null 2>&1 || CLUSTER_OK=false

echo "── Task 1 · 인시던트 트리아지 보고 ──"
file_ok submissions/01-triage.md \
  && ok "submissions/01-triage.md 작성됨" \
  || no "submissions/01-triage.md 없음/내용 부족 (영향 범위·SLO·증상 정리)"

echo "── Task 2 · 근본 원인(RCA) 리포트 ──"
file_ok submissions/02-rca-report.md \
  && ok "submissions/02-rca-report.md 작성됨" \
  || no "submissions/02-rca-report.md 없음/내용 부족 (타임라인·근거·근본원인)"

echo "── Task 3 · 완화 조치 적용 (클러스터 상태) ──"
if $CLUSTER_OK; then
  SCALED=false
  if kubectl -n checkout get hpa -o name 2>/dev/null | grep -q .; then SCALED=true; fi
  REPL=$(kubectl -n checkout get deploy checkout -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
  [ "${REPL:-0}" -gt 2 ] 2>/dev/null && SCALED=true
  PCPU=$(kubectl -n checkout get deploy payment -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null || echo "")
  PCPU_MC=$(mc "$PCPU")
  if $SCALED; then ok "checkout 확장됨 (HPA 존재 또는 replicas>2)"; else no "checkout 미확장 (HPA 추가 또는 replicas 상향 필요)"; fi
  if [ "$PCPU_MC" -gt 150 ] 2>/dev/null; then ok "payment CPU limit 상향됨 (${PCPU} > 150m)"; else no "payment CPU limit 미상향 (현재: ${PCPU:-none})"; fi
else
  no "클러스터에 접근 불가 — checkout 확장 점검 생략 (kubeconfig 확인)"
  no "클러스터에 접근 불가 — payment CPU limit 점검 생략"
fi

echo "── Task 4 · Slack 알림 연동 (Alertmanager + 룰) ──"
if $CLUSTER_OK; then
  AM=$(kubectl -n monitoring get cm alertmanager-config -o jsonpath='{.data.alertmanager\.yml}' 2>/dev/null || echo "")
  echo "$AM" | grep -q "slack-relay" \
    && ok "Alertmanager 가 slack-relay 로 라우팅하도록 구성됨" \
    || no "Alertmanager 에 slack-relay 리시버/라우팅 없음"
  R4=$(kubectl -n monitoring get cm prometheus-rules -o jsonpath='{.data.rules-task4\.yml}' 2>/dev/null || echo "")
  echo "$R4" | grep -q "alert:" \
    && ok "RED/USE 알림 룰(rules-task4.yml)이 추가됨" \
    || no "rules-task4.yml 에 alert 룰 없음 (RED/USE 알림 작성 필요)"
else
  no "클러스터에 접근 불가 — Alertmanager 점검 생략"
  no "클러스터에 접근 불가 — 알림 룰 점검 생략"
fi

echo "── Task 5 · 사후 개선 RFC + 유사 사례 벤치마킹 ──"
file_ok submissions/05-rfc.md \
  && ok "submissions/05-rfc.md 작성됨" \
  || no "submissions/05-rfc.md 없음/내용 부족 (재발방지 RFC + 외부 포스트모템 1건)"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
