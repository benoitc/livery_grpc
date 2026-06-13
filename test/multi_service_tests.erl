-module(multi_service_tests).

-include_lib("eunit/include/eunit.hrl").

%% Two user services (from two different protos) on one listener, both
%% called on the same connection, routed by path. This is the documented
%% "one server, many services" pattern.

-define(GREETER, #{proto => helloworld_pb, service => 'Greeter', handler => greeter_server}).
-define(ROUTEGUIDE, #{proto => route_guide_pb, service => 'RouteGuide', handler => route_guide}).

multi_service_test_() ->
    {setup, fun start/0, fun stop/1, fun(Ctx) ->
        [greeter_call(Ctx), routeguide_call(Ctx)]
    end}.

start() ->
    {ok, _} = application:ensure_all_started(livery_grpc),
    {ok, Server} = livery_grpc:start_server(#{
        port => 0,
        reflection => true,
        services => [?GREETER, ?ROUTEGUIDE, livery_grpc_health:service()]
    }),
    #{server => Server, port => livery_grpc:server_port(Server)}.

stop(#{server := Server}) ->
    ok = livery_grpc:stop_server(Server).

greeter_call(#{port := Port}) ->
    fun() ->
        with_conn(Port, fun(Conn) ->
            {ok, M} = livery_grpc_client:method(helloworld_pb, 'Greeter', 'SayHello'),
            ?assertEqual(
                {ok, #{message => <<"hello multi">>}},
                livery_grpc_client:call(Conn, M, #{name => <<"multi">>})
            )
        end)
    end.

routeguide_call(#{port := Port}) ->
    fun() ->
        with_conn(Port, fun(Conn) ->
            {ok, M} = livery_grpc_client:method(route_guide_pb, 'RouteGuide', 'GetFeature'),
            ?assertEqual(
                {ok, #{name => <<"Point One">>, location => #{latitude => 1, longitude => 1}}},
                livery_grpc_client:call(Conn, M, #{latitude => 1, longitude => 1})
            )
        end)
    end.

with_conn(Port, Fun) ->
    {ok, Conn} = livery_grpc_client:connect("localhost", Port),
    try
        Fun(Conn)
    after
        livery_grpc_client:close(Conn)
    end.
