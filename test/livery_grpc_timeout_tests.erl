-module(livery_grpc_timeout_tests).

-include_lib("eunit/include/eunit.hrl").

parse_units_test() ->
    ?assertEqual(infinity, livery_grpc_timeout:parse(undefined)),
    ?assertEqual(5000, livery_grpc_timeout:parse(<<"5S">>)),
    ?assertEqual(100, livery_grpc_timeout:parse(<<"100m">>)),
    ?assertEqual(60000, livery_grpc_timeout:parse(<<"1M">>)),
    ?assertEqual(3600000, livery_grpc_timeout:parse(<<"1H">>)),
    %% Sub-millisecond rounds up so a positive timeout is never 0.
    ?assertEqual(1, livery_grpc_timeout:parse(<<"500u">>)),
    ?assertEqual(1, livery_grpc_timeout:parse(<<"1n">>)).

parse_malformed_relaxes_test() ->
    ?assertEqual(infinity, livery_grpc_timeout:parse(<<"abc">>)),
    ?assertEqual(infinity, livery_grpc_timeout:parse(<<"S">>)),
    ?assertEqual(infinity, livery_grpc_timeout:parse(<<"10X">>)),
    ?assertEqual(infinity, livery_grpc_timeout:parse(<<>>)).

encode_test() ->
    ?assertEqual(undefined, livery_grpc_timeout:encode(infinity)),
    ?assertEqual(<<"100m">>, livery_grpc_timeout:encode(100)),
    %% Beyond 8 digits of ms falls back to whole seconds.
    ?assertEqual(<<"100001S">>, livery_grpc_timeout:encode(100000001)).

roundtrip_ms_test() ->
    [
        ?assertEqual(Ms, livery_grpc_timeout:parse(livery_grpc_timeout:encode(Ms)))
     || Ms <- [0, 1, 100, 5000, 99999999]
    ].
