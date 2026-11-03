#!/usr/bin/env bash
# About: end-to-end check of the running cluster. Asserts Flux reconciled
# every layer, every HelmRelease is Ready, Grafana reports its Prometheus,
# Loki and Tempo datasources healthy, Alloy ships pod logs to Loki, a
# trace sent to Alloy over OTLP is retrievable from Tempo, and Kyverno
# reports Pod Security baseline violations in policy reports.
set -uo pipefail

NS=monitoring
fail=0
pids=()
cleanup() { for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

pass() { echo "PASS $*"; }
die()  { echo "FAIL $*"; fail=1; }

forward() { # forward <svc> <local-port> <remote-port>
  kubectl -n "$NS" port-forward "svc/$1" "$2:$3" >/dev/null 2>&1 &
  pids+=($!)
}

wait_http() { # wait_http <url>
  for _ in $(seq 1 30); do curl -s -o /dev/null "$1" && return 0; sleep 1; done
  return 1
}

for ks in flux-system infrastructure-sources kyverno monitoring; do
  ready=$(kubectl -n flux-system get kustomization "$ks" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  [[ "$ready" == "True" ]] && pass "kustomization $ks Ready" || die "kustomization $ks not Ready"
done

for ref in kyverno/kyverno kyverno/kyverno-policies \
           monitoring/kube-prometheus-stack monitoring/loki monitoring/tempo monitoring/alloy; do
  ready=$(kubectl -n "${ref%/*}" get helmrelease "${ref#*/}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  [[ "$ready" == "True" ]] && pass "helmrelease $ref Ready" || die "helmrelease $ref not Ready"
done

[[ $fail -eq 0 ]] || exit 1

forward kube-prometheus-stack-grafana 13000 80
forward loki 13100 3100
forward tempo 13200 3200
forward alloy 14318 4318
wait_http http://localhost:13000/api/health || die "grafana port-forward"

user=$(kubectl -n "$NS" get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-user}' | base64 -d)
pw=$(kubectl -n "$NS" get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d)

for uid in prometheus loki tempo; do
  status=$(curl -s -u "$user:$pw" "http://localhost:13000/api/datasources/uid/$uid/health" | jq -r .status)
  [[ "$status" == "OK" ]] && pass "grafana datasource $uid healthy" || die "grafana datasource $uid status=$status"
done

lines=0
for _ in $(seq 1 30); do
  lines=$(curl -sG http://localhost:13100/loki/api/v1/query_range \
    --data-urlencode "query={namespace=\"$NS\"}" --data-urlencode limit=5 \
    | jq '[.data.result[].values[]] | length' 2>/dev/null || echo 0)
  [[ "$lines" -gt 0 ]] && break; sleep 2
done
[[ "$lines" -gt 0 ]] && pass "loki has logs from namespace $NS" || die "loki has no logs from namespace $NS"

trace_id=$(openssl rand -hex 16)
span_id=$(openssl rand -hex 8)
now=$(date +%s)000000000
wait_http http://localhost:14318 || die "alloy port-forward"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost:14318/v1/traces \
  -H 'Content-Type: application/json' -d @- <<JSON
{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"e2e-test"}}]},
 "scopeSpans":[{"spans":[{"traceId":"$trace_id","spanId":"$span_id","name":"e2e-span","kind":1,
 "startTimeUnixNano":"$now","endTimeUnixNano":"$now"}]}]}]}
JSON
)
[[ "$code" == "200" ]] && pass "alloy accepted OTLP span" || die "alloy OTLP push http=$code"

found=0
for _ in $(seq 1 30); do
  curl -sf "http://localhost:13200/api/traces/$trace_id" >/dev/null && { found=1; break; }
  sleep 2
done
[[ $found -eq 1 ]] && pass "tempo returns trace $trace_id" || die "tempo has no trace $trace_id"

# node-exporter uses hostNetwork, hostPID and hostPath, so baseline must flag it.
violations=0
for _ in $(seq 1 30); do
  violations=$(kubectl -n "$NS" get policyreports -o json 2>/dev/null \
    | jq '[.items[].results[]? | select(.result == "fail")] | length' 2>/dev/null || echo 0)
  [[ "$violations" -gt 0 ]] && break; sleep 2
done
[[ "$violations" -gt 0 ]] && pass "kyverno reports $violations baseline violations in $NS" \
  || die "kyverno reports no baseline violations in $NS"

exit $fail
