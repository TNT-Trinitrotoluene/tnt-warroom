# 🔒 해설 (SPOILER) — TNT Checkout 장애의 정답과 검증법

> ⚠️ **먼저 스스로 풀어보고 열어라.** 이 문서는 근본 원인·확인 방법·5개 과제
> 모델 답안·이해도 질문 정답을 모두 담고 있다. 학습 효과를 위해 최소한
> Task 1·2(트리아지/RCA)를 직접 써 본 뒤 대조하는 걸 권한다.

---

## 0. 한 줄 요약

> **트래픽 증가는 "방아쇠"일 뿐, 근본 원인이 아니다.**
> 진짜 원인은 ① **자동 확장 부재(HPA 없음, replicas 고정)**, ② **payment 의
> CPU limit 과소(150m) → CFS 스로틀링**, ③ **checkout 의 1초 타임아웃이
> 만든 504 폭포(cascading failure)** 의 3중 결함이다. 부하를 줄이면 증상은
> 가라앉지만 결함은 그대로 남는다. **CPU limit 상향 + HPA 추가**가 정답이다.

---

## 1. 무슨 일이 있었나 — 근본 원인 3가지

| # | 결함 | 위치 | 효과 |
|---|---|---|---|
| **F1** | 자동 확장 부재 (HPA 없음, `replicas: 2` 고정) | `gitops/apps/checkout.yaml`, `payment.yaml` | 부하가 늘어도 파드 수가 그대로 → 단위 파드 포화 |
| **F2** | `payment` 의 `limits.cpu: "150m"` 과소 | `gitops/apps/payment.yaml` | CPU 작업(`/pay` 의 sha256 루프)이 CFS 스로틀링에 걸려 응답이 **초 단위**로 느려짐 |
| **F3** | `checkout` 의 `PAYMENT_TIMEOUT=1.0` 초 | `gitops/apps/checkout.yaml` | 느려진 payment 를 1초 만에 끊고 **504** 반환 → 사용자 실패 폭증 |

**방아쇠(trigger, 원인 아님):** `loadgen` 의 `CONCURRENCY=80`
(`gitops/loadgen/loadgen.yaml`, 주석에 "≈ 베이스라인의 3배 부하"). 평소엔
숨어 있던 F1~F3 이 트래픽 3배 상황에서 한꺼번에 드러났다.

### 인과 사슬 (왜 한 줄로 안 끝나는가)

```
트래픽 3배(방아쇠)
   │
   ├─▶ checkout 파드 2개로는 동시요청 감당 못 함  ……………… F1
   │
   └─▶ payment /pay CPU 수요 ↑
          └─▶ limits.cpu=150m 에서 CFS 스로틀링 ……………… F2
                 └─▶ payment 응답이 1초를 초과
                        └─▶ checkout 이 1초 타임아웃에 끊음 … F3
                               └─▶ checkout → 사용자에게 504
                                      └─▶ "결제 안 됨" 고객 폭증
```

핵심 통찰: **사용자가 본 건 checkout 의 504 지만, 진짜 병목은 payment 의
CPU 스로틀링**이다. checkout 만 늘려도(F1만 고쳐도) payment 가 여전히
느리면 504 는 계속된다. 그래서 **F2(payment CPU) 를 같이 고쳐야** 한다.

---

## 2. 어떻게 확인하는가 (증거 수집)

> 포트포워딩 먼저 (별도 터미널들):
> ```bash
> kubectl -n monitoring port-forward svc/grafana 3000:3000
> kubectl -n monitoring port-forward svc/prometheus 9090:9090
> ```
> Grafana: http://localhost:3000 → 대시보드 "TNT Checkout — RED / USE"

### 2-1. RED — 사용자 체감 (증상)

- **Errors:** checkout 의 5xx 비율 급증, 그중 **504 가 지배적**.
  ```promql
  sum by (code) (rate(http_requests_total{app="checkout",path="/checkout"}[1m]))
  ```
  → `code="504"` 시리즈가 치솟으면 타임아웃 캐스케이드 확정.

- **Duration:** checkout p99 ≈ **1초 벽**(타임아웃 값)에 붙어 있음.
  ```promql
  histogram_quantile(0.99,
    sum(rate(http_request_duration_seconds_bucket{app="checkout",path="/checkout"}[5m])) by (le))
  ```
  payment p99 는 **초 단위**로 치솟음(스로틀링 때문):
  ```promql
  histogram_quantile(0.99,
    sum(rate(http_request_duration_seconds_bucket{app="payment",path="/pay"}[5m])) by (le))
  ```

### 2-2. USE — 자원 포화 (원인)

- **payment CPU 스로틀링** (이게 결정적 단서):
  ```promql
  sum(rate(container_cpu_cfs_throttled_periods_total{namespace="checkout",container="payment"}[5m]))
  /
  sum(rate(container_cpu_cfs_periods_total{namespace="checkout",container="payment"}[5m]))
  ```
  → 0.2~0.9 수준(주기의 20~90% 가 스로틀)이면 CPU limit 과소 확정.

- **CPU 사용이 limit 에 붙어 있음:**
  ```promql
  sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="checkout",container="payment"}[5m]))
  ```
  → 0.15 core(=150m) 근처에서 평평하게 천장에 막힘.

### 2-3. kubectl — 설정 결함 직접 확인

```bash
# F2: payment CPU limit 이 150m 인지
kubectl -n checkout get deploy payment \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits}{"\n"}'
#   → {"cpu":"150m","memory":"128Mi"}

# F1: HPA 가 아예 없음 + replicas 고정
kubectl -n checkout get hpa            #   → No resources found
kubectl -n checkout get deploy         #   → checkout 2/2, payment 2/2

# F3: checkout 타임아웃이 1초
kubectl -n checkout get deploy checkout \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}'
#   → PAYMENT_TIMEOUT=1.0

# 방아쇠: loadgen 동시성(=3배 부하)
kubectl -n loadgen get deploy loadgen \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CONCURRENCY")].value}{"\n"}'
#   → 80
```

### 2-4. (선택) OOM 하드 모드

기본값은 OOM 이 잘 안 난다(`LEAK_BYTES=0`, `REQ_BUFFER_BYTES=1MB`). 만약
누군가 동시성을 더 올리거나 버퍼를 키웠다면 checkout 이 OOMKilled 될 수 있다:
```bash
kubectl -n checkout get pods   # RESTARTS 증가 관찰
```
```promql
kube_pod_container_status_last_terminated_reason{namespace="checkout",reason="OOMKilled"}
```

---

## 3. 5개 과제 모델 답안

### Task 1 — 인시던트 트리아지 & 1차 보고 (`submissions/01-triage.md`)

- **증상:** 결제(checkout) 요청의 5xx(주로 504) 비율 급증, p99 지연 ~1s 고정.
- **영향 범위:** checkout 네임스페이스의 사용자 결제 플로우 전체. 결제 실패 →
  매출 직접 타격(고객 이탈/CS 폭증).
- **위반 SLO:** 가용성(에러율) SLO, 지연(p99) SLO 동시 위반.
- **1차 보고(#incident-war-room 톤 예시):**
  > [P1] Checkout 결제 실패율 급등 (504 다수). 14:0x 부터 에러율 5%→수십%.
  > 영향: 사용자 결제 실패. 현재 트리아지 중 — payment 지연/스로틀링 의심,
  > checkout 타임아웃 캐스케이드 확인 중. 다음 업데이트 15분 내.
- **핵심:** 추측 대신 **근거**(Grafana 캡처/PromQL 결과)를 함께 남긴다.

### Task 2 — 근본 원인 리포트 (`submissions/02-rca-report.md`)

타임라인 + 지표 + 근거로 위 **F1·F2·F3** 를 도출한다. 반드시 포함할 것:
- 사용한 PromQL/지표(§2 의 쿼리들)와 그 결과 해석.
- "트래픽 3배는 방아쇠, 근본 원인은 설정 결함"이라는 구분.
- 결정적 단서: **payment CFS 스로틀링** + **checkout 504(타임아웃)** 의 연결.

### Task 3 — 완화 적용 & 검증 (클러스터 상태로 채점)

**적용 순서가 중요하다** (payment CPU 먼저, 그다음 HPA):
```bash
# ① payment CPU limit 상향 (F2)
kubectl -n checkout patch deploy payment --patch-file solutions/03-payment-fix.yaml

# ② checkout/payment HPA 추가 (F1)
kubectl apply -f solutions/03-hpa.yaml

# 검증
kubectl -n checkout get hpa
kubectl top pods -n checkout
./verify.sh
```
- **확인:** 적용 후 Grafana 에서 504 비율↓, checkout p99↓, payment 스로틀링↓.
- **영구화(권장):** patch 대신 `gitops/apps/payment.yaml` 자체를 고쳐
  `kubectl apply -k gitops/` (다음 `up.sh` 에도 유지).
- (선택) F3: payment 가 빨라졌으니 1초 타임아웃은 유지해도 됨. 타임아웃은
  "원인"이 아니라 "증상 증폭기"였다 — 굳이 늘려서 가리지 말 것.

### Task 4 — Slack 알림 연동 완성 (클러스터 상태로 채점)

1. `solutions/04-rules-task4.yml` 내용을
   `gitops/monitoring/prometheus-rules.yaml` 의 `rules-task4.yml` 키에 붙여넣기.
2. `solutions/04-alertmanager.yml` 내용을
   `gitops/monitoring/alertmanager.yaml` 의 `alertmanager.yml` 키에 붙여넣기.
3. 적용 & 반영:
   ```bash
   kubectl apply -k gitops/
   kubectl -n monitoring rollout restart deploy/prometheus deploy/alertmanager
   ./verify.sh
   ```
4. **실제 Slack 전송 점검**(웹훅 동작 확인):
   ```bash
   kubectl -n monitoring port-forward deploy/slack-relay 8080:8080
   curl -X POST "localhost:8080/alert?channel=warroom" -H 'Content-Type: application/json' \
     -d '{"status":"firing","alerts":[{"labels":{"severity":"warning","alertname":"Test"},"annotations":{"summary":"relay 점검"}}]}'
   ```
   → `#incident-war-room` 채널에 메시지가 떠야 한다. (안 뜨면 `.env` 웹훅 URL 확인)

### Task 5 — 사후 개선 RFC + 유사 사례 (`submissions/05-rfc.md`)

재발 방지 아키텍처 개선안에 담을 것(예):
- **용량/탄력성:** 모든 사용자 경로 서비스에 HPA(+ requests/limits 재설정),
  부하시험(load test)으로 baseline·헤드룸 산정. (필요시 PodDisruptionBudget,
  Cluster Autoscaler.)
- **복원력:** 호출 측 타임아웃·재시도(백오프)·서킷브레이커 표준화,
  과부하 시 graceful degradation.
- **관측성/알림:** RED/USE 대시보드 표준화, SLO 기반 알림(에러버짓), 채널 라우팅.
- **거버넌스:** 리소스 limit 기본값/리뷰 체크리스트, 변경 시 부하영향 평가.
- **외부 포스트모템 1건 비교**(직접 찾아 인용): 예) "Cascading failure /
  retry storm / lack of autoscaling" 키워드로 공개 포스트모템을 찾아, 그 팀의
  탐지→완화→재발방지 흐름을 우리 사례와 표로 대조한다. (Google SRE Book
  "Addressing Cascading Failures" 장을 근거 문헌으로 함께 인용하면 좋다.)

---

## 4. 이해도 질문 7 (정답 포함)

**Q1. RED 와 USE 는 무엇이 다르며, 이번 장애에서 결정적이었던 지표는?**
RED(Rate·Errors·Duration)는 **요청/사용자 관점**(서비스가 사용자에게 어떻게
보이나), USE(Utilization·Saturation·Errors)는 **자원 관점**(노드/컨테이너가
포화됐나)이다. 이번엔 RED 로 *증상*(checkout 504·p99 1s)을, USE 로 *원인*
(payment CPU **스로틀링**=saturation)을 잡았다. 결정타는
`container_cpu_cfs_throttled_periods_total` 비율.

**Q2. CPU `request` 와 `limit` 의 차이, 그리고 낮은 `limits.cpu` 가 왜
지연을 만드나?**
`request` 는 스케줄링·보장 몫, `limit` 는 상한이다. CPU limit 은 리눅스
**CFS quota**(주기당 사용 가능 시간)로 강제된다. payment 의 `/pay` 는
sha256 루프(CPU bound)인데 limit 150m 이면 100ms 주기당 15ms 만 쓰고
나머지는 **스로틀(대기)** 된다. 그래서 실제 계산 시간이 늘어나
응답이 초 단위로 느려진다. (메모리 limit 초과는 OOMKill, CPU 는 스로틀로
다르게 동작한다는 점도 핵심.)

**Q3. payment 가 느려졌는데 왜 사용자는 checkout 의 **504** 를 보나?**
checkout 이 payment 를 `PAYMENT_TIMEOUT=1.0s` 로 호출한다. payment 가 1초
안에 답을 못 주면 checkout 은 `URLError` 로 끊고 **504** 를 반환한다
(코드 상 `urllib.error.URLError → code=504`). 하위 의존성의 지연이 상위
서비스의 실패로 전파되는 **캐스케이딩 실패**다. 사용자는 checkout 만 보지만
병목은 payment 에 있다.

**Q4. "트래픽 3배"는 원인인가 방아쇠인가? 부하를 줄이는 게 해결책이 아닌 이유는?**
**방아쇠**다. 3배 부하는 평소 숨어 있던 F1~F3 을 드러냈을 뿐, 결함 자체가
아니다. 부하를 줄이면 증상은 사라지지만 결함(확장 부재·CPU limit 과소·취약한
타임아웃)은 그대로라서 다음 트래픽 급증에 재발한다. 그래서 랩 제약(C2)이
"loadgen 을 끄지 말라"고 못 박는다 — 증상 은폐가 아니라 **근본 수정**이 목표.

**Q5. HPA 가 있었다면 장애가 어떻게 달라졌나? metrics-server 는 왜 필요하고,
HPA "만"으로 충분한가?**
HPA 가 있었다면 CPU 사용률 상승에 따라 checkout/payment 파드를 자동 증설해
단위 파드 포화(F1)를 완화했을 것이다. HPA 의 Resource 메트릭은
**metrics-server** 가 제공하므로 그게 없으면 HPA 가 동작하지 않는다(GKE 는
기본 제공). 단, **HPA 만으로는 부족**하다: payment 의 limit 이 150m 그대로면
파드를 늘려도 각 파드가 여전히 스로틀링되고, 게다가 "스로틀링으로 사용률이
높게 잡혀" 엉뚱하게 과확장될 수 있다. **F2(limit 상향)와 함께** 가야 한다.

**Q6. checkout 의 메모리 사용이 동시성에 따라 늘어나는 이유와, limit 을
올리는 것과 동시성을 제어하는 것 중 무엇이 옳은가?**
checkout 은 요청 1건당 `bytearray(REQ_BUFFER_BYTES=1MB)` 를 처리 동안
점유한다. 스레드 동시 처리량이 늘면 동시 점유 버퍼 합이 커져 메모리가
상승하고, 한계 시 OOMKilled 가 된다. 메모리 limit 을 올리면 즉시 죽지는
않지만 **근본 해법은 동시성/백프레셔 제어**(혹은 요청당 메모리 절감)다.
무작정 limit 만 키우면 노드 메모리를 잠식해 다른 워크로드까지 위험해진다 —
limit 상향은 임시 완충, 부하 제어가 정공법.

**Q7. Task 4 알림 임계값을 "이번 장애에 딱 맞게" 잡으면 안 되는 이유와,
좋은 알림 설계 원칙은?**
이번 수치(예: 504 폭증)에 과적합하면 **다음 장애 유형은 못 잡고**, 정상
변동에도 오탐하거나(알림 피로) 늦게 탐지한다. 좋은 알림은 ①
**SLO/사용자 영향 기준**(에러율·p99 SLO 위반)으로 잡고(=RED), ② USE 지표는
**원인 진단 보조**로 두며, ③ **severity 로 채널 라우팅**해 P0(critical →
`#alerts-critical`, 즉시 대응)과 공유성 경보(warning → `#incident-war-room`)를
분리한다. `for:` 지속시간과 `send_resolved` 로 깜빡임/해소까지 관리한다.

---

## 5. 정리

- 증상(RED) → 원인(USE) → 설정 결함(kubectl) 순으로 좁혀라.
- 트래픽은 방아쇠, 고칠 것은 **확장성·CPU limit·복원력**.
- 완화는 **payment CPU → HPA** 순서로, 검증은 `./verify.sh` 로.
- 알림은 이번 사건이 아니라 **SLO** 를 보고 설계하라.

> 학습 끝나면 비용 정지: `./down.sh` (클러스터까지 삭제). 완전 초기화는 `./cleanup.sh`.
