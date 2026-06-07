# TNT SRE War-Room — GKE 장애 대응 & 아키텍처 개선 롤플레잉

> **트랙 성격:** 실전 인시던트 시뮬레이션 (블라인드)
> **플랫폼:** GCP GKE (Standard) · Prometheus/Grafana · Alertmanager → Slack · ArgoCD GitOps
> **난이도:** ★★★★ (복합 요인)
> **당신의 역할:** TNT 결제 플랫폼에 새로 합류한 DevOps/SRE 엔지니어

이 랩은 **원인을 알려주지 않는다.** 당신은 알람과 지표, 흐름을 직접 보고
무엇이 잘못됐는지 *스스로* 규명해야 한다. 정답 해설은 다 풀어본 뒤
[`solutions/README.md`](./solutions/README.md) 에서 연다.

---

## 1. 시나리오 배경 (인시던트 발생)

오늘 당신은 **온콜(on-call)** 이다. 방금 이런 상황이 동시에 터졌다.

- ☎️ **고객센터 에스컬레이션:** "결제/주문이 안 된다"는 고객 문의가 몇 분 사이 폭증.
- 🔔 **#alerts-critical:** 시스템 봇이 **막연한 인프라 알람** 하나만 띄웠다.
  (정확히 무엇이, 왜 깨졌는지는 알려주지 않는다 — *현재 알림 체계가 그 정도뿐이다.*)
- 📉 결제 경로(money-path)의 사용자 체감 품질이 무너지고 있다. 매출 직결 구간이다.

당신에게 주어진 것은 **클러스터 접근 권한과 관측 도구(Grafana/Prometheus)** 뿐이다.
원인 진단도, 보고도, 재발 방지도 전부 당신 몫이다.

### 협업 채널 (Slack, 3개)

| 채널 | 용도 |
|---|---|
| `#alerts-critical`   | 시스템 봇이 P0 알람을 쏘는 곳 (지금은 부실하다 — Task 4 에서 당신이 고친다) |
| `#incident-war-room` | 엔지니어가 모여 원인 분석·임시 조치를 공유하는 상황실 (Task 1·2·3 보고) |
| `#architecture-rfc`  | 장애 종료 후 사후 보고·근본 개선을 논의 (Task 5 RFC) |

> 🎭 **롤플레잉 규칙:** 이 채널들은 실제 Slack 으로 연결할 수 있다(Task 4). 그 전까지
> Task 1·2·5 의 "보고"는 `submissions/*.md` 에 글로 남긴다(= 채널에 올린 셈 친다).

---

## 2. 학습 목표

- **RED**(Rate·Errors·Duration) 와 **USE**(Utilization·Saturation·Errors) 메서드로
  장애를 *측정 기반으로* 진단한다.
- 증상(symptom)과 근본 원인(root cause)을 구분하고, **트리거 ≠ 원인** 을 체득한다.
- 임시 완화(mitigation)와 근본 개선(remediation)을 분리해서 사고한다.
- 관측 → 알림(Alertmanager→Slack) → 사후 개선(RFC) 으로 이어지는 **인시던트 생애주기**를 직접 돈다.

---

## 3. 아키텍처 (당신이 인계받은 것)

당신은 "이 시스템이 어떻게 생겼는지"까지만 안다. *어디가 고장났는지는 모른다.*

```
                 [ loadgen ]  (ns: loadgen)
            상시 합성 사용자 트래픽 (실사용자 부하를 모사)
                       │  HTTP GET /checkout
                       ▼
        ┌────────────────────────────┐
        │   checkout  (ns: checkout)  │   결제 진입점. 매 요청마다 payment 호출.
        └─────────────┬──────────────┘
                       │  HTTP GET /pay
                       ▼
        ┌────────────────────────────┐
        │   payment   (ns: checkout)  │   결제 처리(연산 작업 수행).
        └────────────────────────────┘

  관측 (ns: monitoring):
    Prometheus ── 스크레이프 ──> checkout/payment(/metrics), cAdvisor, node-exporter, kube-state-metrics
    Grafana    ── 대시보드 "TNT Checkout — RED / USE"
    Alertmanager ──> slack-relay ──> Slack(#채널)   ※ 연동은 미완성(=Task 4)
```

- 두 앱(`checkout`, `payment`)은 각자 **`/metrics`** 로 RED 지표(요청 수·코드·지연 히스토그램)를 노출한다.
- 배포는 **ArgoCD 가 `gitops/` 를 동기화한다는 GitOps 전제**로 선언되어 있다.
  (로컬에서는 `up.sh` 가 동일하게 `kubectl apply -k gitops/` 로 적용한다.)

> 💡 토폴로지를 안다고 원인을 아는 건 아니다. *어느 구간이, 왜 무너지는지*는 지표로 좁혀야 한다.

---

## 4. 환경 기동 & 접속

### 사전 준비 (1회)
```bash
cp .env.example .env      # GCP/Slack 값 입력 (Slack 은 Task 4 전까지 비워도 됨)
gcloud auth application-default login    # 또는 서비스계정 키 경로를 .env 에 지정
```

### 기동
```bash
./up.sh                   # Terraform 으로 GKE 생성 → 모니터링/앱/부하 배포 (수 분)
# ./up.sh --with-argocd   # (선택) ArgoCD 까지 설치하려면
```

### 접속 (각각 새 터미널)
```bash
kubectl -n monitoring port-forward svc/grafana 3000:3000      # http://localhost:3000
kubectl -n monitoring port-forward svc/prometheus 9090:9090   # http://localhost:9090
kubectl -n monitoring port-forward svc/alertmanager 9093:9093

kubectl -n loadgen logs deploy/loadgen -f                     # 트래픽 실시간 성적표
kubectl -n checkout get pods -w
```

Grafana 대시보드 **"TNT Checkout — RED / USE"** 가 1차 관측 지점이다. (익명 Admin 로그인)

---

## 5. 관찰 시작점 (도구 사용법 — *정답이 아니라 방법*)

원인은 안 알려준다. 대신 **어떻게 볼지**를 정리해 둔다. 아래는 일반적인 진단 1차 도구다.

### RED (요청 관점 — 서비스가 사용자에게 어떻게 보이나)
```promql
# Rate: 초당 요청수 (코드별)
sum by (app, code) (rate(http_requests_total[1m]))
# Errors: 5xx 비율
sum(rate(http_requests_total{code=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))
# Duration: p99 지연
histogram_quantile(0.99, sum by (app, le) (rate(http_request_duration_seconds_bucket[5m])))
```

### USE (자원 관점 — 어디가 포화됐나)
```promql
# Saturation(CPU): CFS 스로틀링
sum by (pod, container) (rate(container_cpu_cfs_throttled_seconds_total{namespace="checkout"}[5m]))
# Saturation(MEM): 워킹셋 vs limit
container_memory_working_set_bytes{namespace="checkout",container!=""}
kube_pod_container_resource_limits{namespace="checkout",resource="memory"}
# Errors(재시작/OOM)
kube_pod_container_status_restarts_total{namespace="checkout"}
kube_pod_container_status_last_terminated_reason{namespace="checkout"}
```

### kubectl 1차 점검
```bash
kubectl -n checkout get deploy,pod,hpa
kubectl -n checkout describe deploy <name>     # resources / 복제수 / 프로브
kubectl -n checkout get events --sort-by=.lastTimestamp | tail -30
kubectl top pods -n checkout                    # (metrics-server 필요)
```

> 🧭 **진단 사고법:** RED 로 *증상*(누가 아픈가)을 잡고, USE 로 *원인 자원*(왜 아픈가)을
> 좁힌 뒤, 배포 스펙(`describe`)으로 *설정 결함*을 확정한다. 한 지표만 보고 단정하지 마라.

---

## 6. 필수 해결 과제 (5)

> 모든 과제는 "문제를 미리 알려주는" 형태가 아니다. 상태를 보고하고, 직접 규명하고,
> 재발을 막는 **프로세스** 과제다.

### Task 1 — 인시던트 트리아지 & 1차 영향 보고
- 지금 시스템 상태를 RED/USE 로 **신속 파악**한다.
- **영향 범위**를 산정한다: 영향받는 서비스, 추정 사용자 영향, 위반/위협받는 SLO.
- `submissions/01-triage.md` 에 `#incident-war-room` 1차 보고 톤으로 정리한다.
  *(원인 단정은 아직 필요 없다 — "무엇이 얼마나 아픈가"를 먼저 잡아라.)*

### Task 2 — 근본 원인 조사 리포트 (RCA)
- 진단 과정을 **타임라인**으로 적고, 사용한 **지표/PromQL/이벤트**를 근거로 첨부한다.
- 근본 원인 **가설과 근거**를 `submissions/02-rca-report.md` 에 정리한다.
  *(증상과 원인을 구분하라. "트래픽이 많다"는 트리거일 뿐 원인이 아닐 수 있다.)*

### Task 3 — 서비스 회복(완화) 적용 & 검증
- 직접 규명한 원인에 맞춰 **최소·안전한 완화 조치**를 적용해 지표를 SLO 이내로 되돌린다.
- 조치 **전/후**를 Grafana(RED 에러율·p99)로 **검증**한다.
  *(제약은 §7 참고. 트래픽을 끄거나 코드로 증상을 가리는 건 회복이 아니다.)*

### Task 4 — 재발 자동 감지: Slack 알림 연동 완성
- 현재 알림은 인프라 레벨만 본다(그래서 이번 장애를 조기에 못 잡았다).
- **Prometheus 알림 룰**(`prometheus-rules` 의 `rules-task4.yml`)과
  **Alertmanager 라우팅**(`alertmanager-config`)을 완성해, 동일 장애 재발 시
  `slack-relay` 를 거쳐 **실제 Slack 채널**로 알람이 가도록 한다.
- 임계값·`severity` 라벨·채널 라우팅(P0→`#alerts-critical`)을 **설계**한다.
  *(어떤 지표로 알람을 걸지는 Task 2 에서 찾은 원인에 근거해 정한다.)*

### Task 5 — 사후 개선 RFC + 유사 사례 벤치마킹
- `#architecture-rfc` 에 **재발 방지 근본 개선안(RFC)** 을 `submissions/05-rfc.md` 로 작성한다.
- 업계의 **유사 장애 포스트모템 1건 이상**을 조사해, 그 팀의 대응/교훈과 우리 안을 비교한다.

---

## 7. 제약 조건 (반드시 지킨다)

| # | 제약 | 이유 |
|---|---|---|
| C1 | `checkout` · `monitoring` · `loadgen` 네임스페이스 **밖은 건드리지 않는다** | 다른 랩/시스템 보호 |
| C2 | **loadgen(트래픽)을 끄거나 줄여서 "해결"하지 않는다** | 이 트래픽은 정상 사용자 부하를 모사한 것. 시스템이 견뎌야 한다 (회피 ≠ 해결) |
| C3 | **앱 소스(`*-src` ConfigMap 의 `app.py`)를 고쳐 증상을 숨기지 않는다** | 인프라/배포 설정으로 해결한다 (예: 타임아웃만 늘려 5xx 가리기 금지) |
| C4 | Pod 강제 삭제(`--force`)로 임시 회피만 하지 않는다 | 근본 조치 후 자연 rollout 으로 적용 |
| C5 | Task 4 의 기존 `starter` 룰은 지우지 말고 **추가**한다 | 알림은 누적 설계 |

---

## 8. 검증

```bash
./verify.sh
# 항목별 PASS/FAIL + 마지막 줄 "PASS=n FAIL=m". 모두 통과 시 exit 0.
```

`verify.sh` 가 보는 것(완료 기준):
- Task 1·2·5: `submissions/*.md` 산출물 존재/분량
- Task 3: 클러스터 상태(확장 여부, 자원 설정 변경)
- Task 4: Alertmanager 의 slack 라우팅 + `rules-task4.yml` 의 알림 룰 추가

**수동 검증(권장):** Grafana 에서 조치 후 **에러율이 0 근처로, p99 가 SLO 이내로** 회복되는지,
재발 시 **실제 Slack 채널**에 메시지가 오는지 눈으로 확인한다.

---

## 9. 진행 함정 (process pitfalls)

1. **첫 지표 하나로 단정** — RED 만 보고 "앱 버그"라 결론내기 전에 USE 로 자원을 본다.
2. **트리거를 원인으로 착각** — 부하 증가는 *드러나게 한* 트리거일 수 있다. 부하가 정상이어도
   견뎠어야 하는지 자문하라.
3. **증상 가리기** — 타임아웃·재시도만 늘리면 그래프는 잠깐 좋아져도 근본은 그대로다.
4. **완화=해결 혼동** — 급한 불(Task 3)과 재발 방지(Task 5)는 다른 작업이다.
5. **알림 과적합** — Task 4 임계값을 이번 사건에만 맞추면 다음엔 또 못 잡는다. SLO 기반으로.

---

## 10. 정답 위치

충분히 시도한 뒤에만 연다. 무엇이 문제였는지, 어떻게 확인하는지, 5과제 모범답안과
**이해도 점검 질문 7개**가 들어 있다.

```
solutions/README.md
```

---

## 11. 정리 (비용 주의 ⚠️)

GKE 는 **실제 과금**된다. 실습이 끝나면 반드시 정리한다.

```bash
./down.sh        # Terraform destroy — 클러스터/노드/VPC 삭제 (과금 중단)
./cleanup.sh     # down + 로컬 Terraform 상태/캐시 삭제
gcloud container clusters list --project tih-testproject   # 남은 게 없는지 최종 확인
```
