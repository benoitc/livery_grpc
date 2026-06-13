-module(livery_grpc_server_sup).
-moduledoc """
Dynamic supervisor for gRPC listeners.

`livery_grpc:start_server/1` adds a `livery_grpc_listener` child here, so
each running server is supervised and outlives the process that started
it. `stop_server/1` terminates the child.
""".
-behaviour(supervisor).

-export([start_link/0, start_server/1, stop_server/1]).
-export([init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc "Start a supervised listener; returns its owner pid.".
-spec start_server(livery_grpc_listener:start_opts()) -> {ok, pid()} | {error, term()}.
start_server(StartOpts) ->
    supervisor:start_child(?MODULE, [StartOpts]).

-doc "Stop a supervised listener by its owner pid.".
-spec stop_server(pid()) -> ok | {error, term()}.
stop_server(Pid) ->
    supervisor:terminate_child(?MODULE, Pid).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{strategy => simple_one_for_one, intensity => 5, period => 10},
    Child = #{
        id => livery_grpc_listener,
        start => {livery_grpc_listener, start_link, []},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [livery_grpc_listener]
    },
    {ok, {SupFlags, [Child]}}.
