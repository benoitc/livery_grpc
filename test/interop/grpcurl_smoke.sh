#!/usr/bin/env bash
# Interop smoke test: drive a running livery_grpc server with grpcurl, a
# real external gRPC client. Proves on-the-wire compliance (framing,
# trailers, status, health). Skipped if grpcurl is not installed.
#
# Usage: test/interop/grpcurl_smoke.sh
set -euo pipefail

cd "$(dirname "$0")/../.."

if ! command -v grpcurl >/dev/null 2>&1; then
  echo "grpcurl not found; skipping interop smoke test."
  exit 0
fi

PORT=50071

rebar3 as examples compile >/dev/null

# Start a Greeter server (with health) in the background.
erl -noshell \
  -pa _build/examples/lib/*/ebin \
  -pa _build/examples/checkouts/*/ebin \
  -pa _build/examples/lib/livery_grpc/examples \
  -eval "application:ensure_all_started(livery_grpc),
         {ok,_}=livery_grpc:start_server(#{port=>${PORT},
           services=>[#{proto=>helloworld_pb,service=>'Greeter',handler=>greeter_example},
                      livery_grpc_health:service()]}),
         timer:sleep(60000), halt()." &
SERVER_PID=$!
trap 'kill ${SERVER_PID} 2>/dev/null || true' EXIT

# Wait for the port to accept connections.
for _ in $(seq 1 30); do
  if nc -z localhost ${PORT} 2>/dev/null; then break; fi
  sleep 0.2
done

fail() { echo "FAIL: $1"; exit 1; }

echo "== unary =="
OUT=$(grpcurl -plaintext -proto proto/helloworld.proto \
  -d '{"name":"interop"}' localhost:${PORT} helloworld.Greeter/SayHello)
echo "$OUT"
echo "$OUT" | grep -q "hello interop" || fail "unary reply"

echo "== server-stream =="
OUT=$(grpcurl -plaintext -proto proto/helloworld.proto \
  -d '{"name":"x"}' localhost:${PORT} helloworld.Greeter/SayHelloStream)
echo "$OUT"
[ "$(echo "$OUT" | grep -c message)" -eq 3 ] || fail "expected 3 stream messages"

echo "== client-streaming =="
OUT=$(printf '{"name":"a"}\n{"name":"b"}\n{"name":"c"}\n' | \
  grpcurl -plaintext -proto proto/helloworld.proto \
  -d @ localhost:${PORT} helloworld.Greeter/SayHelloCollect)
echo "$OUT"
echo "$OUT" | grep -q "hello a, b, c" || fail "client-streaming reply"

echo "== bidirectional =="
OUT=$(printf '{"name":"x"}\n{"name":"y"}\n' | \
  grpcurl -plaintext -proto proto/helloworld.proto \
  -d @ localhost:${PORT} helloworld.Greeter/SayHelloChat)
echo "$OUT"
[ "$(echo "$OUT" | grep -c message)" -eq 2 ] || fail "expected 2 bidi replies"

echo "== health =="
OUT=$(grpcurl -plaintext -proto proto/health.proto \
  -d '{"service":""}' localhost:${PORT} grpc.health.v1.Health/Check)
echo "$OUT"
echo "$OUT" | grep -q SERVING || fail "health status"

echo "All grpcurl interop checks passed."
