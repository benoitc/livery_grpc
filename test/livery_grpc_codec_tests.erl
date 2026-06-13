-module(livery_grpc_codec_tests).

-include_lib("eunit/include/eunit.hrl").

%% Uses the generated helloworld_pb module (built from proto/helloworld.proto).

encode_decode_roundtrip_test() ->
    Msg = #{name => <<"world">>},
    {ok, Bin} = livery_grpc_codec:encode(helloworld_pb, 'HelloRequest', Msg),
    ?assert(is_binary(Bin)),
    ?assertEqual({ok, Msg}, livery_grpc_codec:decode(helloworld_pb, 'HelloRequest', Bin)).

decode_error_is_value_test() ->
    %% Garbage bytes surface as an error tuple, not an exception.
    Result = livery_grpc_codec:decode(helloworld_pb, 'HelloRequest', <<255, 255, 255>>),
    ?assertMatch({error, {decode, _}}, Result).

content_type_test() ->
    ?assert(livery_grpc_codec:is_grpc_content_type(<<"application/grpc">>)),
    ?assert(livery_grpc_codec:is_grpc_content_type(<<"application/grpc+proto">>)),
    ?assert(livery_grpc_codec:is_grpc_content_type(<<"application/grpc; charset=utf-8">>)),
    ?assertNot(livery_grpc_codec:is_grpc_content_type(<<"application/json">>)),
    ?assertNot(livery_grpc_codec:is_grpc_content_type(undefined)).
