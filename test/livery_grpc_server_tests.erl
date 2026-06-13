-module(livery_grpc_server_tests).

-include_lib("eunit/include/eunit.hrl").

%% End-to-end tests for the gRPC server. The server runs on a real h2c
%% listener; requests are driven with the raw `h2` client (the logic that
%% becomes livery_grpc_client in the next phase).

-define(GREETER, #{proto => helloworld_pb, service => 'Greeter', handler => greeter_server}).

server_test_() ->
    {setup, fun start/0, fun stop/1, fun(Ctx) ->
        [
            unary_ok(Ctx),
            unary_error(Ctx),
            unary_crash(Ctx),
            unknown_method(Ctx),
            server_stream(Ctx)
        ]
    end}.

start() ->
    {ok, _} = application:ensure_all_started(livery_grpc),
    {ok, Server} = livery_grpc:start_server(#{port => 0, services => [?GREETER]}),
    #{server => Server, port => livery_grpc:server_port(Server)}.

stop(#{server := Server}) ->
    ok = livery_grpc:stop_server(Server).

%%====================================================================
%% Cases
%%====================================================================

unary_ok(#{port := Port}) ->
    fun() ->
        {Status, Replies, GrpcStatus, _Msg} =
            call(Port, <<"/helloworld.Greeter/SayHello">>, [#{name => <<"ada">>}]),
        ?assertEqual(200, Status),
        ?assertEqual(ok, GrpcStatus),
        ?assertEqual([#{message => <<"hello ada">>}], Replies)
    end.

unary_error(#{port := Port}) ->
    fun() ->
        {200, Replies, GrpcStatus, Msg} =
            call(Port, <<"/helloworld.Greeter/SayHello">>, [#{name => <<"boom">>}]),
        ?assertEqual(invalid_argument, GrpcStatus),
        ?assertEqual(<<"no boom allowed">>, Msg),
        ?assertEqual([], Replies)
    end.

unary_crash(#{port := Port}) ->
    fun() ->
        {200, [], GrpcStatus, _Msg} =
            call(Port, <<"/helloworld.Greeter/SayHello">>, [#{name => <<"crash">>}]),
        ?assertEqual(internal, GrpcStatus)
    end.

unknown_method(#{port := Port}) ->
    fun() ->
        {200, [], GrpcStatus, _Msg} =
            call(Port, <<"/helloworld.Greeter/Nope">>, [#{name => <<"x">>}]),
        ?assertEqual(unimplemented, GrpcStatus)
    end.

server_stream(#{port := Port}) ->
    fun() ->
        {200, Replies, GrpcStatus, _Msg} =
            call(Port, <<"/helloworld.Greeter/SayHelloStream">>, [#{name => <<"sam">>}]),
        ?assertEqual(ok, GrpcStatus),
        ?assertEqual(
            [
                #{message => <<"hi sam #1">>},
                #{message => <<"hi sam #2">>},
                #{message => <<"hi sam #3">>}
            ],
            Replies
        )
    end.

%%====================================================================
%% Minimal gRPC client over the raw h2 client
%%====================================================================

%% Send one request message (unary/server-stream shape) and collect the
%% response: {HttpStatus, [DecodedReply], GrpcStatusAtom, GrpcMessage}.
call(Port, Path, RequestMsgs) ->
    Headers = [
        {<<":method">>, <<"POST">>},
        {<<":path">>, Path},
        {<<":scheme">>, <<"http">>},
        {<<":authority">>, <<"localhost">>},
        {<<"content-type">>, <<"application/grpc+proto">>},
        {<<"te">>, <<"trailers">>}
    ],
    %% Connect inside the calling (test) process so it owns the stream
    %% events the h2 client delivers to the connection owner.
    {ok, Conn} = h2:connect("localhost", Port, #{transport => tcp}),
    try
        {ok, StreamId} = h2:request(Conn, Headers, #{end_stream => false}),
        Body = iolist_to_binary([frame(M) || M <- RequestMsgs]),
        ok = h2:send_data(Conn, StreamId, Body, true),
        collect(Conn, StreamId, undefined, [], undefined)
    after
        h2:close(Conn)
    end.

frame(Msg) ->
    Bin = helloworld_pb:encode_msg(Msg, 'HelloRequest'),
    livery_grpc_frame:encode(Bin).

collect(Conn, StreamId, Status, DataAcc, Trailers) ->
    receive
        {h2, Conn, {response, StreamId, S, H}} ->
            %% Trailers-only: grpc-status rides in the response headers.
            case grpc_status(H) of
                undefined -> collect(Conn, StreamId, S, DataAcc, Trailers);
                _ -> finish(S, DataAcc, H)
            end;
        {h2, Conn, {data, StreamId, Data, _Fin}} ->
            collect(Conn, StreamId, Status, [Data | DataAcc], Trailers);
        {h2, Conn, {trailers, StreamId, T}} ->
            finish(Status, DataAcc, T);
        {h2, Conn, {stream_reset, StreamId, Reason}} ->
            error({stream_reset, Reason})
    after 2000 ->
        error({timeout, Status, DataAcc})
    end.

finish(Status, DataAcc, StatusHeaders) ->
    Bin = iolist_to_binary(lists:reverse(DataAcc)),
    Replies = decode_frames(Bin),
    {GrpcStatus, Msg} = grpc_result(StatusHeaders),
    {Status, Replies, GrpcStatus, Msg}.

decode_frames(Bin) ->
    {Frames, <<>>} = livery_grpc_frame:push(Bin, livery_grpc_frame:new()),
    [helloworld_pb:decode_msg(P, 'HelloReply') || {false, P} <- Frames].

grpc_status(Headers) ->
    proplists:get_value(<<"grpc-status">>, Headers).

grpc_result(Headers) ->
    Status = livery_grpc_status:from_binary(proplists:get_value(<<"grpc-status">>, Headers)),
    Msg =
        case proplists:get_value(<<"grpc-message">>, Headers) of
            undefined -> <<>>;
            Encoded -> livery_grpc_status:decode_message(Encoded)
        end,
    {Status, Msg}.
