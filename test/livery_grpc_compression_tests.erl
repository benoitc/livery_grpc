-module(livery_grpc_compression_tests).

-include_lib("eunit/include/eunit.hrl").

identity_test() ->
    ?assertEqual({false, <<"abc">>}, livery_grpc_compression:compress(identity, <<"abc">>)),
    Decode = livery_grpc_compression:decompress(false, identity),
    ?assertEqual(<<"abc">>, Decode(<<"abc">>)).

gzip_roundtrip_test() ->
    Payload = binary:copy(<<"livery_grpc ">>, 64),
    {Flag, Compressed} = livery_grpc_compression:compress(gzip, Payload),
    ?assert(Flag),
    Decode = livery_grpc_compression:decompress(true, gzip),
    ?assertEqual(Payload, Decode(Compressed)).

flag_clear_ignores_algorithm_test() ->
    %% A clear flag means identity regardless of negotiated algorithm.
    Decode = livery_grpc_compression:decompress(false, gzip),
    ?assertEqual(<<"raw">>, Decode(<<"raw">>)).

header_parsing_test() ->
    ?assertEqual(identity, livery_grpc_compression:from_header(undefined)),
    ?assertEqual(identity, livery_grpc_compression:from_header(<<"identity">>)),
    ?assertEqual(gzip, livery_grpc_compression:from_header(<<"gzip">>)),
    ?assertEqual(identity, livery_grpc_compression:from_header(<<"snappy">>)).

supported_test() ->
    ?assert(livery_grpc_compression:is_supported(gzip)),
    ?assert(livery_grpc_compression:is_supported(identity)),
    ?assertNot(livery_grpc_compression:is_supported(snappy)).
