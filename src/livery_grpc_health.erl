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
registered. `Watch` streams the current status and then a new message
every time it changes, until the client disconnects.

Status and watch subscriptions live in `livery_grpc_health_store`, a
gen_server started with the application.
""".

-export([service/0]).
-export([set_serving/0, set_serving/1, set_not_serving/0, set_not_serving/1, status/1]).
-export([check/2, watch/3]).

-export_type([serving_status/0]).

-type serving_status() :: livery_grpc_health_store:serving_status().

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
set_serving(Service) -> livery_grpc_health_store:set(Service, 'SERVING').

-doc "Mark the overall server as not serving.".
-spec set_not_serving() -> ok.
set_not_serving() -> set_not_serving(<<>>).

-doc "Mark a named service as not serving.".
-spec set_not_serving(binary()) -> ok.
set_not_serving(Service) -> livery_grpc_health_store:set(Service, 'NOT_SERVING').

-doc """
The current status for a service name. The overall server (`<<>>`)
defaults to `SERVING`; a never-registered named service is
`SERVICE_UNKNOWN`.
""".
-spec status(binary()) -> serving_status().
status(Service) ->
    case livery_grpc_health_store:status(Service) of
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
    case livery_grpc_health_store:status(service_name(Request)) of
        {ok, Status} -> {ok, #{status => Status}};
        not_found -> {error, {not_found, <<"unknown service">>}}
    end.

-doc """
Server-streaming `Watch`: emit the current status, then a new message on
every change, until the client disconnects.
""".
-spec watch(map(), fun((map()) -> ok | {error, term()}), livery_grpc_server:ctx()) -> ok.
watch(Request, Send, _Ctx) ->
    Service = service_name(Request),
    Status = livery_grpc_health_store:subscribe(Service),
    _ = Send(#{status => Status}),
    watch_loop(Service, Send).

%% Block for status changes (pushed by the store) and for the client
%% disconnect signal livery delivers to the worker. Sending stops the loop
%% if the peer is gone.
-spec watch_loop(binary(), fun((map()) -> ok | {error, term()})) -> ok.
watch_loop(Service, Send) ->
    receive
        {grpc_health_watch, Service, Status} ->
            case Send(#{status => Status}) of
                ok -> watch_loop(Service, Send);
                {error, _} -> ok
            end;
        {livery_disconnect, _Ref, _Reason} ->
            ok
    end.

%%====================================================================
%% Internals
%%====================================================================

-spec service_name(map()) -> binary().
service_name(Request) ->
    maps:get(service, Request, <<>>).
