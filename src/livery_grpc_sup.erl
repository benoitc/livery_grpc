-module(livery_grpc_sup).
-moduledoc """
Top-level supervisor for `livery_grpc`.

Supervises the health status store and the dynamic server supervisor;
gRPC servers started via `livery_grpc:start_server/1` are children of the
latter, so each server outlives the process that started it.
""".
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    Children = [
        #{
            id => livery_grpc_health_store,
            start => {livery_grpc_health_store, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [livery_grpc_health_store]
        },
        #{
            id => livery_grpc_server_sup,
            start => {livery_grpc_server_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [livery_grpc_server_sup]
        }
    ],
    {ok, {SupFlags, Children}}.
