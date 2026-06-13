-module(livery_grpc_listener).
-moduledoc """
Owns a gRPC h2 listener, supervised under `livery_grpc_server_sup`.

The h2 listen socket is owned by whichever process calls `h2:start_server`,
so it must be a long-lived one or the socket closes with it. This
gen_server is that owner: it opens the listener in `init` and holds it for
the lifetime of the supervised child, so a server started from a transient
caller (a test's `init_per_suite`, a short request) keeps running.
""".
-behaviour(gen_server).

-export([start_link/1, port/1, listener/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export_type([start_opts/0]).

-type start_opts() :: #{h2_opts := map()}.

%%====================================================================
%% API
%%====================================================================

-spec start_link(start_opts()) -> {ok, pid()} | {error, term()}.
start_link(StartOpts) ->
    gen_server:start_link(?MODULE, StartOpts, []).

-doc "The TCP port the listener is bound to.".
-spec port(pid()) -> inet:port_number().
port(Pid) ->
    gen_server:call(Pid, port).

-doc "The underlying h2 listener handle.".
-spec listener(pid()) -> livery_h2:listener().
listener(Pid) ->
    gen_server:call(Pid, listener).

%%====================================================================
%% gen_server
%%====================================================================

-spec init(start_opts()) -> {ok, map()} | {stop, term()}.
init(#{h2_opts := H2Opts}) ->
    process_flag(trap_exit, true),
    case livery_h2:start(H2Opts) of
        {ok, Listener} ->
            {ok, #{listener => Listener, port => h2:server_port(Listener)}};
        {error, Reason} ->
            {stop, Reason}
    end.

-spec handle_call(term(), {pid(), term()}, map()) -> {reply, term(), map()}.
handle_call(port, _From, #{port := Port} = State) ->
    {reply, Port, State};
handle_call(listener, _From, #{listener := Listener} = State) ->
    {reply, Listener, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), map()) -> ok.
terminate(_Reason, #{listener := Listener}) ->
    _ = livery_h2:stop(Listener),
    ok;
terminate(_Reason, _State) ->
    ok.

-spec code_change(term(), map(), term()) -> {ok, map()}.
code_change(_Old, State, _Extra) ->
    {ok, State}.
