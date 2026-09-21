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

# Start a Greeter server (with health) in the background. MapEcho comes
# from test/map_fixture.erl, compiled here since this profile has no tests.
erl -noshell \
  -pa _build/examples/lib/*/ebin \
  -pa _build/examples/checkouts/*/ebin \
  -pa _build/examples/lib/livery_grpc/examples \
  -eval "application:ensure_all_started(livery_grpc),
         {ok,Fix,Bin}=compile:file(\"test/map_fixture.erl\",[binary]),
         {module,Fix}=code:load_binary(Fix,\"test/map_fixture.erl\",Bin),
         {ok,_}=livery_grpc:start_server(#{port=>${PORT}, reflection=>true,
           services=>[#{proto=>helloworld_pb,service=>'Greeter',handler=>greeter_example},
                      map_fixture:registration(),
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

echo "== reflection (no -proto) =="
OUT=$(grpcurl -plaintext localhost:${PORT} list)
echo "$OUT"
echo "$OUT" | grep -q "helloworld.Greeter" || fail "reflection list"
# A fully reflective call: no -proto, schema discovered over reflection.
OUT=$(grpcurl -plaintext -d '{"name":"reflected"}' \
  localhost:${PORT} helloworld.Greeter/SayHello)
echo "$OUT"
echo "$OUT" | grep -q "hello reflected" || fail "reflective call"

echo "== reflection: map fields (no -proto) =="
# protoreflect rejects a map field whose entry type is not nested in its
# owner, so describing these proves the served descriptors are well formed.
OUT=$(grpcurl -plaintext localhost:${PORT} describe livery.interop.v1.MapRequest)
echo "$OUT"
echo "$OUT" | grep -q "map<string, string> labels" || fail "describe map field"
echo "$OUT" | grep -q "map<string, string> extra_labels" || fail "describe shared map type"
echo "$OUT" | grep -q "map<int32, .livery.interop.v1.Inner> by_id" || fail "describe nested map"
OUT=$(grpcurl -plaintext localhost:${PORT} describe google.protobuf.Struct)
echo "$OUT"
echo "$OUT" | grep -q "map<string, .google.protobuf.Value> fields" || fail "describe imported map"
OUT=$(grpcurl -plaintext \
  -d '{"labels":{"env":"prod"},"meta":{"name":"interop"},"nested":{"by_id":{"7":{"note":"seven"}}}}' \
  localhost:${PORT} livery.interop.v1.MapEcho/Echo)
echo "$OUT"
echo "$OUT" | grep -q '"env": "prod"' || fail "map call: labels"
echo "$OUT" | grep -q '"name": "interop"' || fail "map call: struct"
echo "$OUT" | grep -q '"note": "seven"' || fail "map call: nested map"

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
