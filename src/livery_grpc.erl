-module(livery_grpc).
-moduledoc """
Public facade: run a gRPC server on a dedicated livery HTTP/2 listener.

A gRPC server is its own listener, serving only gRPC. The dispatcher owns
every stream, routing `POST /package.Service/Method` to the Erlang
callback module bound to that service. One listener per server keeps gRPC
framing and routing separate from any REST surface.

```erlang
{ok, Server} = livery_grpc:start_server(#{
    port     => 50051,
    services => [
        #{proto => helloworld_pb, service => 'Greeter', handler => my_greeter}
    ]
}),
%% my_greeter implements one Erlang function per RPC, named in snake_case:
%%   say_hello(#{name := Name}, _Ctx) -> {ok, #{message => <<"hi ", Name/binary>>}}.
ok = livery_grpc:stop_server(Server).
```

The transport defaults to `tcp` (h2c); pass `transport => ssl` with
`cert` and `key` to serve over TLS with ALPN-negotiated h2. Each service
binds a `handler` module; its callbacks receive the decoded request
message and a context (see `t:livery_grpc_server:ctx/0`).
""".

-export([start_server/1, stop_server/1]).
-export([server_port/1]).

-export_type([server/0, service_spec/0, server_opts/0]).

%% The owner pid of a running server's listener (a supervised process).
-type server() :: pid().

-type service_spec() :: #{
    proto := module(),
    service := atom(),
    handler := module()
}.

-type server_opts() :: #{
    services := [service_spec()],
    port => inet:port_number(),
    transport => tcp | ssl,
    cert => binary() | string(),
    key => binary() | string(),
    cacerts => [binary()],
    ssl_opts => [ssl:tls_server_option()],
    acceptors => pos_integer(),
    %% Outbound message compression (default identity).
    compression => livery_grpc_compression:algorithm(),
    %% Mount the grpc.reflection.v1 service so tools can discover the API.
    reflection => boolean(),
    %% Optional livery middleware stack wrapping the gRPC handler.
    middleware => livery_middleware:stack(),
    config => term()
}.

%% gRPC's conventional default port.
-define(DEFAULT_PORT, 50051).

-doc """
Start a gRPC server on its own h2 listener.

`services` is required: a list of `#{proto, service, handler}` bindings.
Returns the listener handle for `stop_server/1` and `server_port/1`.
""".
-spec start_server(server_opts()) -> {ok, server()} | {error, term()}.
start_server(Opts) when is_map(Opts) ->
    Services = registrations(Opts),
    Index = livery_grpc_service:index(Services),
    Handler = livery_grpc_server:handler(Index, server_config(Opts, Services)),
    %% The listener is owned by a supervised process so it outlives the
    %% caller (the h2 listen socket is owned by whoever opens it).
    livery_grpc_server_sup:start_server(#{h2_opts => h2_opts(Opts, Handler)}).

%% The service list, with the reflection service appended when reflection
%% is enabled.
-spec registrations(server_opts()) -> [livery_grpc_service:registration()].
registrations(Opts) ->
    Services = maps:get(services, Opts),
    case maps:get(reflection, Opts, false) of
        true -> Services ++ [livery_grpc_reflection:service()];
        false -> Services
    end.

-doc "Stop a gRPC server.".
-spec stop_server(server()) -> ok.
stop_server(Server) ->
    _ = livery_grpc_server_sup:stop_server(Server),
    ok.

-doc "The TCP port a running server is bound to.".
-spec server_port(server()) -> inet:port_number().
server_port(Server) ->
    livery_grpc_listener:port(Server).

%%====================================================================
%% Internals
%%====================================================================

%% The livery_grpc_server options: compression plus, when reflection is
%% on, the descriptor set built from every registered service.
-spec server_config(server_opts(), [livery_grpc_service:registration()]) -> map().
server_config(Opts, Services) ->
    Base = maps:with([compression], Opts),
    case maps:get(reflection, Opts, false) of
        true -> Base#{reflection => livery_grpc_reflection:build(Services)};
        false -> Base
    end.

-spec h2_opts(server_opts(), fun((livery_req:req()) -> livery_resp:resp())) -> map().
h2_opts(Opts, Handler) ->
    Base = #{
        port => maps:get(port, Opts, ?DEFAULT_PORT),
        transport => maps:get(transport, Opts, tcp),
        stack => maps:get(middleware, Opts, []),
        handler => Handler,
        config => maps:get(config, Opts, undefined)
    },
    copy_present([cert, key, cacerts, ssl_opts, acceptors, ip, inet6], Opts, Base).

-spec copy_present([atom()], map(), map()) -> map().
copy_present(Keys, Src, Dst) ->
    lists:foldl(
        fun(K, Acc) ->
            case maps:find(K, Src) of
                {ok, V} -> Acc#{K => V};
                error -> Acc
            end
        end,
        Dst,
        Keys
    ).
