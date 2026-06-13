#!/usr/bin/env bash
# Client interop: drive a real grpc-go server with the livery_grpc client,
# proving the client speaks gRPC to a non-Erlang server. The Go server uses
# grpc-go's built-in health service (grpc.health.v1), which our health_pb
# matches. Skipped if Go is not installed.
#
# Usage: test/interop/client_interop.sh
set -euo pipefail

cd "$(dirname "$0")/../.."

if ! command -v go >/dev/null 2>&1; then
  echo "go not found; skipping client interop test."
  exit 0
fi

PORT=50051

rebar3 compile >/dev/null

# Start the grpc-go health server (listens on :50051).
( cd test/interop/gohealth && GOTOOLCHAIN=local go run . >/tmp/livery_grpc_gosrv.log 2>&1 ) &
GO_PID=$!
trap 'kill ${GO_PID} 2>/dev/null || true; pkill -f "gohealth" 2>/dev/null || true' EXIT

for _ in $(seq 1 60); do
  if nc -z localhost ${PORT} 2>/dev/null; then break; fi
  sleep 1
done

# Call it with the livery_grpc client; each match fails the run on mismatch.
erl -noshell \
  -pa _build/default/lib/*/ebin \
  -pa _build/default/checkouts/*/ebin \
  -eval '
    try
        {ok, _} = application:ensure_all_started(livery_grpc),
        {ok, Conn} = livery_grpc_client:connect("localhost", 50051),
        {ok, Chk} = livery_grpc_client:method(health_pb, '\''Health'\'', '\''Check'\''),
        {ok, #{status := '\''SERVING'\''}} = livery_grpc_client:call(Conn, Chk, #{service => <<>>}),
        {ok, #{status := '\''NOT_SERVING'\''}} =
            livery_grpc_client:call(Conn, Chk, #{service => <<"livery.Test">>}),
        {error, {not_found, _}} =
            livery_grpc_client:call(Conn, Chk, #{service => <<"nope">>}),
        {ok, W} = livery_grpc_client:method(health_pb, '\''Health'\'', '\''Watch'\''),
        {ok, Call} = livery_grpc_client:open(Conn, W),
        ok = livery_grpc_client:send(Call, #{service => <<>>}),
        ok = livery_grpc_client:send_end(Call),
        {ok, #{status := '\''SERVING'\''}, _} = livery_grpc_client:recv(Call),
        livery_grpc_client:close(Conn),
        io:format("client interop against grpc-go: OK~n"),
        halt(0)
    catch
        Class:Reason:Stack ->
            io:format("client interop FAILED: ~p:~p~n~p~n", [Class, Reason, Stack]),
            halt(1)
    end.'
