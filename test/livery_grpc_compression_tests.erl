-module(livery_grpc_compression_tests).

-include_lib("eunit/include/eunit.hrl").

identity_test() ->
    ?assertEqual({false, <<"abc">>}, livery_grpc_compression:compress(identity, <<"abc">>)),
    ?assertEqual(<<"abc">>, livery_grpc_compression:decompress(false, identity, <<"abc">>)).

gzip_roundtrip_test() ->
    Payload = binary:copy(<<"livery_grpc ">>, 64),
    {Flag, Compressed} = livery_grpc_compression:compress(gzip, Payload),
    ?assert(Flag),
    ?assertEqual(Payload, livery_grpc_compression:decompress(true, gzip, Compressed)).

flag_clear_ignores_algorithm_test() ->
    %% A clear flag means identity regardless of negotiated algorithm.
    ?assertEqual(<<"raw">>, livery_grpc_compression:decompress(false, gzip, <<"raw">>)).

flag_set_for_identity_raises_test() ->
    ?assertError(
        {grpc_compression, flag_set_for_identity},
        livery_grpc_compression:decompress(true, identity, <<"x">>)
    ).

header_parsing_test() ->
    ?assertEqual(identity, livery_grpc_compression:from_header(undefined)),
    ?assertEqual(identity, livery_grpc_compression:from_header(<<"identity">>)),
    ?assertEqual(gzip, livery_grpc_compression:from_header(<<"gzip">>)),
    ?assertEqual(identity, livery_grpc_compression:from_header(<<"snappy">>)).

supported_test() ->
    ?assert(livery_grpc_compression:is_supported(gzip)),
    ?assert(livery_grpc_compression:is_supported(identity)),
    ?assertNot(livery_grpc_compression:is_supported(snappy)).
