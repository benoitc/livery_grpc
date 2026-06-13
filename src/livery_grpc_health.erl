-module(livery_grpc_health).
-moduledoc """
The standard `grpc.health.v1.Health` service, ready to mount.

Register it on a server with `service/0`:

```erlang
livery_grpc:start_server(#{
    port     => 50051,
    services => [my_service_spec, livery_grpc_health:service()]
}).
```

Serving status is held per service name (the empty name `<<>>` is the
overall server status, which defaults to `SERVING`). Set it with
`set_serving/0,1` and `set_not_serving/0,1`. `Check` returns the current
status, or a `not_found` gRPC error for a named service that was never
registered. `Watch` emits the current status once; live status streaming
follows the bidirectional h2 work.

Status is stored in a `persistent_term`, so changes are global to the node
and meant to be infrequent (startup, drain).
""".

-export([service/0]).
-export([set_serving/0, set_serving/1, set_not_serving/0, set_not_serving/1, status/1]).
-export([check/2, watch/3]).

-export_type([serving_status/0]).

-define(KEY, {?MODULE, statuses}).

-type serving_status() :: 'UNKNOWN' | 'SERVING' | 'NOT_SERVING' | 'SERVICE_UNKNOWN'.

%%====================================================================
%% Registration and status control
%%====================================================================

-doc "The service spec to pass in a server's `services` list.".
-spec service() -> livery_grpc_service:registration().
service() ->
    #{proto => health_pb, service => 'Health', handler => ?MODULE}.

-doc "Mark the overall server as serving.".
-spec set_serving() -> ok.
set_serving() -> set_serving(<<>>).

-doc "Mark a named service as serving.".
-spec set_serving(binary()) -> ok.
set_serving(Service) -> put_status(Service, 'SERVING').

-doc "Mark the overall server as not serving.".
-spec set_not_serving() -> ok.
set_not_serving() -> set_not_serving(<<>>).

-doc "Mark a named service as not serving.".
-spec set_not_serving(binary()) -> ok.
set_not_serving(Service) -> put_status(Service, 'NOT_SERVING').

-doc """
The current status for a service name. The overall server (`<<>>`)
defaults to `SERVING`; a never-registered named service is
`SERVICE_UNKNOWN`.
""".
-spec status(binary()) -> serving_status().
status(Service) ->
    case lookup(Service) of
        {ok, Status} -> Status;
        not_found -> 'SERVICE_UNKNOWN'
    end.

%%====================================================================
%% gRPC callbacks
%%====================================================================

-doc "Unary `Check`: the current serving status, or a not_found error.".
-spec check(map(), livery_grpc_server:ctx()) ->
    {ok, map()} | {error, {livery_grpc_status:status(), binary()}}.
check(Request, _Ctx) ->
    case lookup(service_name(Request)) of
        {ok, Status} -> {ok, #{status => Status}};
        not_found -> {error, {not_found, <<"unknown service">>}}
    end.

-doc "Server-streaming `Watch`: emit the current status once.".
-spec watch(map(), fun((map()) -> ok | {error, term()}), livery_grpc_server:ctx()) ->
    ok | {error, {livery_grpc_status:status(), binary()}}.
watch(Request, Send, _Ctx) ->
    case lookup(service_name(Request)) of
        {ok, Status} ->
            _ = Send(#{status => Status}),
            ok;
        not_found ->
            {error, {not_found, <<"unknown service">>}}
    end.

%%====================================================================
%% Internals
%%====================================================================

-spec service_name(map()) -> binary().
service_name(Request) ->
    maps:get(service, Request, <<>>).

%% The overall server defaults to SERVING even when nothing was set; a
%% named service must have been registered to be known.
-spec lookup(binary()) -> {ok, serving_status()} | not_found.
lookup(Service) ->
    Statuses = persistent_term:get(?KEY, #{}),
    case maps:find(Service, Statuses) of
        {ok, Status} -> {ok, Status};
        error when Service =:= <<>> -> {ok, 'SERVING'};
        error -> not_found
    end.

-spec put_status(binary(), serving_status()) -> ok.
put_status(Service, Status) ->
    Statuses = persistent_term:get(?KEY, #{}),
    persistent_term:put(?KEY, Statuses#{Service => Status}).
