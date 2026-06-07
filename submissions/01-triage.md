### 징쥬
```
현재 사용자 대기 시간이 길어진다는 연락 받고, grafana RED 지표 확인해보았습니다

RPS : 502, 504 각 70, 7 정도의 값으로 지속
p99: 잠시 완화된듯 보이나 실제로는 pod 재가동 시간이랑 겹쳐 낮아짐
CPU throttling: payment pod들이 1을 웃돌고 있는 상황

payment 쪽 부터 확인 후 변경상황 있으면 추가 보고 드리겠습니다

Grafana:
http://localhost:3000/d/tnt-reduse/tnt-checkout-e28094-red-use?orgId=1&refresh=10s
```

### 깜찍 우기!
```
```