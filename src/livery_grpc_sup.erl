-module(livery_grpc_sup).
-moduledoc """
Top-level supervisor for `livery_grpc`.

Supervises the health status store. gRPC servers (each a dedicated livery
h2 listener) are started via `livery_grpc:start_server/1` and own their own
listener supervision tree.
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
        }
    ],
    {ok, {SupFlags, Children}}.
