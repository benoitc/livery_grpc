-module(livery_grpc_health_store).
-moduledoc """
Serving-status store behind `livery_grpc_health`, with watch subscriptions.

Holds the per-service status and the set of watchers. Setting a status
pushes a `{grpc_health_watch, Service, Status}` message to every watcher of
that service, which is how `Watch` streams live updates. Watchers are
monitored, so a disconnected watcher is dropped automatically.

The empty service name (`<<>>`) is the overall server status and defaults
to `SERVING`; a named service that was never set is unknown.
""".
-behaviour(gen_server).

-export([start_link/0, set/2, status/1, subscribe/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export_type([serving_status/0]).

-type serving_status() :: 'UNKNOWN' | 'SERVING' | 'NOT_SERVING' | 'SERVICE_UNKNOWN'.

-record(state, {
    statuses = #{} :: #{binary() => serving_status()},
    %% Service -> set of watcher pids and their monitor refs.
    watchers = #{} :: #{binary() => #{pid() => reference()}},
    %% Monitor ref -> {Service, Pid}, for O(1) cleanup on DOWN.
    monitors = #{} :: #{reference() => {binary(), pid()}}
}).

-define(SERVER, ?MODULE).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-doc "Set a service's serving status and notify its watchers.".
-spec set(binary(), serving_status()) -> ok.
set(Service, Status) ->
    gen_server:call(?SERVER, {set, Service, Status}).

-doc """
The current status for `Check`: `{ok, Status}`, or `not_found` for a named
service that was never registered (the overall server defaults to
`SERVING`).
""".
-spec status(binary()) -> {ok, serving_status()} | not_found.
status(Service) ->
    gen_server:call(?SERVER, {status, Service}).

-doc """
Register the caller as a watcher of `Service` and return the current
status to emit first. A named unknown service resolves to
`SERVICE_UNKNOWN` (Watch keeps the stream open rather than erroring).
""".
-spec subscribe(binary()) -> serving_status().
subscribe(Service) ->
    gen_server:call(?SERVER, {subscribe, Service, self()}).

%%====================================================================
%% gen_server
%%====================================================================

-spec init([]) -> {ok, #state{}}.
init([]) ->
    {ok, #state{}}.

-spec handle_call(term(), {pid(), term()}, #state{}) -> {reply, term(), #state{}}.
handle_call({status, Service}, _From, State) ->
    {reply, lookup(Service, State), State};
handle_call({subscribe, Service, Pid}, _From, State) ->
    MRef = erlang:monitor(process, Pid),
    State1 = add_watcher(Service, Pid, MRef, State),
    {reply, resolve(Service, State), State1};
handle_call({set, Service, Status}, _From, #state{statuses = Statuses} = State) ->
    notify(Service, Status, State),
    {reply, ok, State#state{statuses = Statuses#{Service => Status}}};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info({'DOWN', MRef, process, _Pid, _Reason}, State) ->
    {noreply, drop_watcher(MRef, State)};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), #state{}) -> ok.
terminate(_Reason, _State) ->
    ok.

-spec code_change(term(), #state{}, term()) -> {ok, #state{}}.
code_change(_Old, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internals
%%====================================================================

-spec lookup(binary(), #state{}) -> {ok, serving_status()} | not_found.
lookup(Service, #state{statuses = Statuses}) ->
    case maps:find(Service, Statuses) of
        {ok, Status} -> {ok, Status};
        error when Service =:= <<>> -> {ok, 'SERVING'};
        error -> not_found
    end.

-spec resolve(binary(), #state{}) -> serving_status().
resolve(Service, State) ->
    case lookup(Service, State) of
        {ok, Status} -> Status;
        not_found -> 'SERVICE_UNKNOWN'
    end.

-spec add_watcher(binary(), pid(), reference(), #state{}) -> #state{}.
add_watcher(Service, Pid, MRef, #state{watchers = Watchers, monitors = Monitors} = State) ->
    ForService = maps:get(Service, Watchers, #{}),
    State#state{
        watchers = Watchers#{Service => ForService#{Pid => MRef}},
        monitors = Monitors#{MRef => {Service, Pid}}
    }.

-spec drop_watcher(reference(), #state{}) -> #state{}.
drop_watcher(MRef, #state{watchers = Watchers, monitors = Monitors} = State) ->
    case maps:take(MRef, Monitors) of
        {{Service, Pid}, Monitors1} ->
            ForService = maps:remove(Pid, maps:get(Service, Watchers, #{})),
            State#state{watchers = Watchers#{Service => ForService}, monitors = Monitors1};
        error ->
            State
    end.

-spec notify(binary(), serving_status(), #state{}) -> ok.
notify(Service, Status, #state{watchers = Watchers}) ->
    Pids = maps:keys(maps:get(Service, Watchers, #{})),
    lists:foreach(fun(Pid) -> Pid ! {grpc_health_watch, Service, Status} end, Pids).
