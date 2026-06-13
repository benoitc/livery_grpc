-module(livery_grpc_streaming_tests).

-include_lib("eunit/include/eunit.hrl").

%% Client-streaming and bidirectional, client against the in-tree server.

-define(GREETER, #{proto => helloworld_pb, service => 'Greeter', handler => greeter_server}).

streaming_test_() ->
    {setup, fun start/0, fun stop/1, fun(Ctx) ->
        [
            client_stream(Ctx),
            bidi(Ctx)
        ]
    end}.

start() ->
    {ok, _} = application:ensure_all_started(livery_grpc),
    {ok, Server} = livery_grpc:start_server(#{port => 0, services => [?GREETER]}),
    #{server => Server, port => livery_grpc:server_port(Server)}.

stop(#{server := Server}) ->
    ok = livery_grpc:stop_server(Server).

client_stream(#{port := Port}) ->
    fun() ->
        with_conn(Port, fun(Conn) ->
            {ok, M} = livery_grpc_client:method(helloworld_pb, 'Greeter', 'SayHelloCollect'),
            Requests = [#{name => <<"a">>}, #{name => <<"b">>}, #{name => <<"c">>}],
            ?assertEqual(
                {ok, #{message => <<"hello a, b, c">>}},
                livery_grpc_client:client_stream(Conn, M, Requests)
            )
        end)
    end.

bidi(#{port := Port}) ->
    fun() ->
        with_conn(Port, fun(Conn) ->
            {ok, M} = livery_grpc_client:method(helloworld_pb, 'Greeter', 'SayHelloChat'),
            {ok, Call} = livery_grpc_client:open(Conn, M),
            %% Ping-pong: send a request, read its echo, three times.
            Replies = [pingpong(Call, N) || N <- [<<"x">>, <<"y">>, <<"z">>]],
            ok = livery_grpc_client:send_end(Call),
            {eof, Outcome, _} = livery_grpc_client:recv(Call),
            ?assertEqual(ok, Outcome),
            ?assertEqual(
                [
                    #{message => <<"hi x">>},
                    #{message => <<"hi y">>},
                    #{message => <<"hi z">>}
                ],
                Replies
            )
        end)
    end.

pingpong(Call, Name) ->
    ok = livery_grpc_client:send(Call, #{name => Name}),
    {ok, Reply, _} = livery_grpc_client:recv(Call),
    Reply.

with_conn(Port, Fun) ->
    {ok, Conn} = livery_grpc_client:connect("localhost", Port),
    try
        Fun(Conn)
    after
        livery_grpc_client:close(Conn)
    end.
