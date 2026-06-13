-module(livery_grpc_health_tests).

-include_lib("eunit/include/eunit.hrl").

health_test_() ->
    {setup, fun start/0, fun stop/1, fun(Ctx) ->
        [
            overall_defaults_serving(Ctx),
            named_serving(Ctx),
            not_serving(Ctx),
            unknown_service(Ctx),
            watch_live_updates(Ctx)
        ]
    end}.

start() ->
    {ok, _} = application:ensure_all_started(livery_grpc),
    {ok, Server} = livery_grpc:start_server(#{port => 0, services => [livery_grpc_health:service()]}),
    livery_grpc_health:set_serving(<<"api">>),
    livery_grpc_health:set_not_serving(<<"db">>),
    #{server => Server, port => livery_grpc:server_port(Server)}.

stop(#{server := Server}) ->
    ok = livery_grpc:stop_server(Server).

overall_defaults_serving(#{port := Port}) ->
    fun() -> ?assertEqual({ok, #{status => 'SERVING'}}, check(Port, <<>>)) end.

named_serving(#{port := Port}) ->
    fun() -> ?assertEqual({ok, #{status => 'SERVING'}}, check(Port, <<"api">>)) end.

not_serving(#{port := Port}) ->
    fun() -> ?assertEqual({ok, #{status => 'NOT_SERVING'}}, check(Port, <<"db">>)) end.

unknown_service(#{port := Port}) ->
    fun() -> ?assertMatch({error, {not_found, _}}, check(Port, <<"ghost">>)) end.

%% Watch streams the current status, then a new message when it changes.
watch_live_updates(#{port := Port}) ->
    fun() ->
        {ok, M} = livery_grpc_client:method(health_pb, 'Health', 'Watch'),
        with_conn(Port, fun(Conn) ->
            {ok, Call} = livery_grpc_client:open(Conn, M),
            ok = livery_grpc_client:send(Call, #{service => <<"api">>}),
            ok = livery_grpc_client:send_end(Call),
            %% Initial status; receiving it proves the watch is registered.
            {ok, #{status := 'SERVING'}, Call1} = livery_grpc_client:recv(Call),
            %% A change is pushed to the open stream.
            ok = livery_grpc_health:set_not_serving(<<"api">>),
            ?assertMatch({ok, #{status := 'NOT_SERVING'}, _}, livery_grpc_client:recv(Call1))
        end)
    end.

check(Port, Service) ->
    {ok, M} = livery_grpc_client:method(health_pb, 'Health', 'Check'),
    with_conn(Port, fun(Conn) ->
        livery_grpc_client:call(Conn, M, #{service => Service})
    end).

with_conn(Port, Fun) ->
    {ok, Conn} = livery_grpc_client:connect("localhost", Port),
    try
        Fun(Conn)
    after
        livery_grpc_client:close(Conn)
    end.
