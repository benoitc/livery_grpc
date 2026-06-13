-module(route_guide_example_tests).

-include_lib("eunit/include/eunit.hrl").

%% Exercise the RouteGuide example (examples/route_guide.erl) end to end:
%% all four call types against a real server.

route_guide_test_() ->
    {setup, fun start/0, fun stop/1, fun(Ctx) ->
        [
            get_feature(Ctx),
            list_features(Ctx),
            record_route(Ctx),
            route_chat(Ctx)
        ]
    end}.

start() ->
    {ok, Server} = route_guide:start(0),
    #{server => Server, port => livery_grpc:server_port(Server)}.

stop(#{server := Server}) ->
    ok = livery_grpc:stop_server(Server).

get_feature(#{port := Port}) ->
    fun() ->
        with_conn(Port, fun(Conn) ->
            ?assertEqual(
                {ok, #{name => <<"Point One">>, location => #{latitude => 1, longitude => 1}}},
                livery_grpc_client:call(Conn, m('GetFeature'), #{latitude => 1, longitude => 1})
            )
        end)
    end.

list_features(#{port := Port}) ->
    fun() ->
        with_conn(Port, fun(Conn) ->
            {ok, Features} = livery_grpc_client:call(Conn, m('ListFeatures'), #{
                lo => #{latitude => 0, longitude => 0},
                hi => #{latitude => 10, longitude => 10}
            }),
            Names = [N || #{name := N} <- Features],
            ?assertEqual([<<"Point One">>, <<"Point Five">>], Names)
        end)
    end.

record_route(#{port := Port}) ->
    fun() ->
        with_conn(Port, fun(Conn) ->
            ?assertEqual(
                {ok, #{point_count => 2, feature_count => 2, distance => 8}},
                livery_grpc_client:client_stream(Conn, m('RecordRoute'), [
                    #{latitude => 1, longitude => 1}, #{latitude => 5, longitude => 5}
                ])
            )
        end)
    end.

route_chat(#{port := Port}) ->
    fun() ->
        with_conn(Port, fun(Conn) ->
            {ok, Chat} = livery_grpc_client:open(Conn, m('RouteChat')),
            Loc = #{latitude => 1, longitude => 1},
            ok = livery_grpc_client:send(Chat, #{location => Loc, message => <<"first">>}),
            %% No prior note at this point yet, so send a second to get the echo.
            ok = livery_grpc_client:send(Chat, #{location => Loc, message => <<"second">>}),
            ?assertMatch(
                {ok, #{location := Loc, message := <<"first">>}, _},
                livery_grpc_client:recv(Chat)
            )
        end)
    end.

m(Name) ->
    {ok, M} = livery_grpc_client:method(route_guide_pb, 'RouteGuide', Name),
    M.

with_conn(Port, Fun) ->
    {ok, Conn} = livery_grpc_client:connect("localhost", Port),
    try
        Fun(Conn)
    after
        livery_grpc_client:close(Conn)
    end.
