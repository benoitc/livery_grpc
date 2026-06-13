-module(livery_grpc_app).
-moduledoc """
Application callback for `livery_grpc`.

Starts the top-level supervisor. The application owns no listeners by
itself; gRPC servers are started on demand via `livery_grpc:start_server/1`
and supervised under `livery_grpc_sup`.
""".
-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    livery_grpc_sup:start_link().

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
