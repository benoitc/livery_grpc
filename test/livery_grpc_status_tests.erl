-module(livery_grpc_status_tests).

%% proper before eunit (see livery_grpc_frame_tests for the why).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(STATUSES, [
    ok,
    cancelled,
    unknown,
    invalid_argument,
    deadline_exceeded,
    not_found,
    already_exists,
    permission_denied,
    resource_exhausted,
    failed_precondition,
    aborted,
    out_of_range,
    unimplemented,
    internal,
    unavailable,
    data_loss,
    unauthenticated
]).

code_name_roundtrip_test() ->
    [
        ?assertEqual(S, livery_grpc_status:name(livery_grpc_status:code(S)))
     || S <- ?STATUSES
    ].

codes_are_0_to_16_test() ->
    Codes = [livery_grpc_status:code(S) || S <- ?STATUSES],
    ?assertEqual(lists:seq(0, 16), lists:sort(Codes)).

unknown_code_maps_to_unknown_test() ->
    ?assertEqual(unknown, livery_grpc_status:name(99)).

header_value_test() ->
    ?assertEqual(<<"0">>, livery_grpc_status:to_binary(ok)),
    ?assertEqual(<<"5">>, livery_grpc_status:to_binary(not_found)),
    ?assertEqual(not_found, livery_grpc_status:from_binary(<<"5">>)).

is_code_test() ->
    ?assert(livery_grpc_status:is_code(internal)),
    ?assertNot(livery_grpc_status:is_code(nonsense)),
    ?assertNot(livery_grpc_status:is_code(<<"internal">>)).

trailers_test() ->
    ?assertEqual([{<<"grpc-status">>, <<"0">>}], livery_grpc_status:trailers(ok)),
    ?assertEqual([{<<"grpc-status">>, <<"13">>}], livery_grpc_status:trailers(internal, <<>>)),
    ?assertEqual(
        [{<<"grpc-status">>, <<"13">>}, {<<"grpc-message">>, <<"boom">>}],
        livery_grpc_status:trailers(internal, <<"boom">>)
    ).

message_encoding_test() ->
    %% Printable ASCII passes through; percent is escaped; control/UTF-8 escaped.
    ?assertEqual(<<"hello world">>, livery_grpc_status:encode_message(<<"hello world">>)),
    ?assertEqual(<<"100%25">>, livery_grpc_status:encode_message(<<"100%">>)),
    ?assertEqual(<<"a%0Ab">>, livery_grpc_status:encode_message(<<"a\nb">>)).

proper_message_roundtrip_test_() ->
    {timeout, 30, fun() ->
        ?assert(proper:quickcheck(prop_message_roundtrip(), [{to_file, user}, {numtests, 500}]))
    end}.

prop_message_roundtrip() ->
    ?FORALL(
        Msg,
        binary(),
        livery_grpc_status:decode_message(livery_grpc_status:encode_message(Msg)) =:= Msg
    ).
