#!/usr/bin/env bash
# Checks the model gateway from a laptop with cluster access, through a port-forward.
# It reads; it doesn't change the cluster.
#
#   GATEWAY_KEY=<a key from the gateway-keys Secret> ./scripts/llm-gateway-check.sh
#
# Checks: no key and a wrong key are refused (401), a real key gets an answer (200), and the
# gateway's metrics include tokens and time to first token. Exits non-zero on the first failure.
set -euo pipefail

: "${GATEWAY_KEY:?set GATEWAY_KEY to an API key for the gateway}"
port="${LOCAL_PORT:-14000}"
base="http://127.0.0.1:${port}"
pass=0

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok:   $*"; pass=$((pass + 1)); }

kubectl -n llm port-forward svc/gateway "${port}:4000" 15020:15020 >/dev/null &
pf=$!
for _ in $(seq 1 20); do
    curl -s -o /dev/null "${base}/" && break
    sleep 0.5
done

tmp="$(mktemp)"
trap 'kill "$pf" 2>/dev/null; wait "$pf" 2>/dev/null || :; rm -f "$tmp"' EXIT

chat() { # $1: the API key to send, or empty for none. Prints the HTTP status
    local body='{"model":"chat","messages":[{"role":"user","content":"What is 2+2? Answer with a number."}],"max_tokens":8}'
    local auth=()
    [ -n "$1" ] && auth=(-H "Authorization: Bearer $1")
    curl -s -o "$tmp" -w '%{http_code}' "${base}/v1/chat/completions" \
        -H 'Content-Type: application/json' "${auth[@]}" -d "$body"
}

code="$(chat "")"
[ "$code" = 401 ] || fail "no key: expected 401, got $code"
ok "no key is refused (401)"

code="$(chat "not-a-real-key")"
[ "$code" = 401 ] || fail "wrong key: expected 401, got $code"
ok "a wrong key is refused (401)"

code="$(chat "$GATEWAY_KEY")"
[ "$code" = 200 ] || fail "real key: expected 200, got $code: $(cat "$tmp")"
answer="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["choices"][0]["message"]["content"])' "$tmp")"
ok "a real key gets an answer (200): ${answer}"

# A streamed request, so the time-to-first-token histogram has a sample
curl -s -N -o /dev/null "${base}/v1/chat/completions" -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${GATEWAY_KEY}" \
    -d '{"model":"chat","stream":true,"messages":[{"role":"user","content":"Name a colour."}],"max_tokens":6}'

metrics="$(curl -s http://127.0.0.1:15020/metrics)"
grep -q '^agentgateway_gen_ai_client_token_usage_sum' <<<"$metrics" || fail "no token usage metric"
ok "token usage metric present"
grep -q '^agentgateway_gen_ai_server_time_to_first_token_count' <<<"$metrics" || fail "no time-to-first-token metric"
ok "time-to-first-token metric present"

echo "all ${pass} checks passed"
