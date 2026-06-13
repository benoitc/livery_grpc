-module(livery_grpc_web_tests).

-include_lib("eunit/include/eunit.hrl").

%% gRPC-Web end-to-end: the status rides in a trailer frame (flag 0x80) in
%% the body, not in HTTP trailers; the text variant base64s the body. The
%% in-tree client speaks plain gRPC, so these drive the wire by hand.

-define(GREETER, #{proto => helloworld_pb, service => 'Greeter', handler => greeter_server}).

web_test_() ->
    {setup, fun start/0, fun stop/1, fun(Ctx) ->
        [
            binary_unary(Ctx),
            binary_unary_error(Ctx),
            binary_server_stream(Ctx),
            text_unary(Ctx)
        ]
    end}.

start() ->
    {ok, _} = application:ensure_all_started(livery_grpc),
    {ok, Server} = livery_grpc:start_server(#{port => 0, services => [?GREETER]}),
    #{server => Server, port => livery_grpc:server_port(Server)}.

stop(#{server := Server}) ->
    ok = livery_grpc:stop_server(Server).

binary_unary(#{port := Port}) ->
    fun() ->
        {200, Replies, Status} = call(
            Port, <<"application/grpc-web+proto">>, <<"/helloworld.Greeter/SayHello">>, #{
                name => <<"web">>
            }
        ),
        ?assertEqual(ok, Status),
        ?assertEqual([#{message => <<"hello web">>}], Replies)
    end.

binary_unary_error(#{port := Port}) ->
    fun() ->
        {200, Replies, Status} = call(
            Port, <<"application/grpc-web+proto">>, <<"/helloworld.Greeter/SayHello">>, #{
                name => <<"boom">>
            }
        ),
        ?assertEqual(invalid_argument, Status),
        ?assertEqual([], Replies)
    end.

binary_server_stream(#{port := Port}) ->
    fun() ->
        {200, Replies, Status} = call(
            Port, <<"application/grpc-web+proto">>, <<"/helloworld.Greeter/SayHelloStream">>, #{
                name => <<"web">>
            }
        ),
        ?assertEqual(ok, Status),
        ?assertEqual(3, length(Replies))
    end.

text_unary(#{port := Port}) ->
    fun() ->
        {200, Replies, Status} = call(
            Port, <<"application/grpc-web-text">>, <<"/helloworld.Greeter/SayHello">>, #{
                name => <<"txt">>
            }
        ),
        ?assertEqual(ok, Status),
        ?assertEqual([#{message => <<"hello txt">>}], Replies)
    end.

%%====================================================================
%% Raw gRPC-Web client over h2
%%====================================================================

call(Port, ContentType, Path, RequestMsg) ->
    Text = ContentType =:= <<"application/grpc-web-text">>,
    ReqFrame = iolist_to_binary(
        livery_grpc_frame:encode(helloworld_pb:encode_msg(RequestMsg, 'HelloRequest'))
    ),
    Body =
        case Text of
            true -> base64:encode(ReqFrame);
            false -> ReqFrame
        end,
    {ok, Conn} = h2:connect("localhost", Port, #{transport => tcp}),
    try
        Headers = [
            {<<":method">>, <<"POST">>},
            {<<":path">>, Path},
            {<<":scheme">>, <<"http">>},
            {<<":authority">>, <<"localhost">>},
            {<<"content-type">>, ContentType}
        ],
        {ok, StreamId} = h2:request(Conn, Headers, #{end_stream => false}),
        ok = h2:send_data(Conn, StreamId, Body, true),
        {Status, RawBody} = collect(Conn, StreamId, undefined, []),
        Decoded =
            case Text of
                true -> base64:decode(RawBody);
                false -> RawBody
            end,
        {Messages, Trailer} = parse_frames(Decoded, [], undefined),
        Replies = [helloworld_pb:decode_msg(M, 'HelloReply') || M <- Messages],
        {Status, Replies, grpc_status(Trailer)}
    after
        h2:close(Conn)
    end.

collect(Conn, StreamId, Status, Acc) ->
    receive
        {h2, Conn, {response, StreamId, S, _H}} ->
            collect(Conn, StreamId, S, Acc);
        {h2, Conn, {data, StreamId, Data, true}} ->
            {Status, iolist_to_binary(lists:reverse([Data | Acc]))};
        {h2, Conn, {data, StreamId, Data, false}} ->
            collect(Conn, StreamId, Status, [Data | Acc]);
        {h2, Conn, {trailers, StreamId, _T}} ->
            {Status, iolist_to_binary(lists:reverse(Acc))}
    after 2000 ->
        error({timeout, Status})
    end.

%% Split a gRPC-Web body into message payloads and the trailer block. The
%% trailer frame is the one whose flag has the high bit set (0x80).
parse_frames(<<Flag, Len:32/big, Payload:Len/binary, Rest/binary>>, Msgs, Trailer) ->
    case Flag band 128 of
        128 -> parse_frames(Rest, Msgs, Payload);
        0 -> parse_frames(Rest, [Payload | Msgs], Trailer)
    end;
parse_frames(<<>>, Msgs, Trailer) ->
    {lists:reverse(Msgs), Trailer}.

grpc_status(undefined) ->
    undefined;
grpc_status(Block) ->
    %% Block is "grpc-status:0\r\ngrpc-message:...\r\n".
    Lines = binary:split(Block, <<"\r\n">>, [global]),
    Pairs = [list_to_tuple(binary:split(L, <<":">>)) || L <- Lines, L =/= <<>>],
    {_, Code} = lists:keyfind(<<"grpc-status">>, 1, Pairs),
    livery_grpc_status:from_binary(Code).
