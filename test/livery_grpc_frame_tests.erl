-module(livery_grpc_frame_tests).

%% proper before eunit: eunit.hrl defines ?LET guarded by -ifndef(LET),
%% proper_common.hrl defines it unguarded. Including proper first lets
%% eunit skip its own, avoiding a redefinition warning (fatal here).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Unit tests
%%====================================================================

encode_layout_test() ->
    %% Flag byte, 4-byte big-endian length, then payload.
    ?assertEqual(
        <<0, 0, 0, 0, 5, "hello">>,
        iolist_to_binary(livery_grpc_frame:encode(<<"hello">>))
    ),
    ?assertEqual(
        <<1, 0, 0, 0, 3, "abc">>,
        iolist_to_binary(livery_grpc_frame:encode(<<"abc">>, true))
    ).

decode_one_whole_test() ->
    Bin = iolist_to_binary(livery_grpc_frame:encode(<<"hi">>)),
    ?assertEqual({ok, {false, <<"hi">>}, <<>>}, livery_grpc_frame:decode_one(Bin)).

decode_one_partial_test() ->
    ?assertEqual(more, livery_grpc_frame:decode_one(<<0, 0, 0>>)),
    ?assertEqual(more, livery_grpc_frame:decode_one(<<0, 0, 0, 0, 5, "hel">>)).

decode_one_too_large_test() ->
    %% Declared length 100 with Max 10: rejected before reading payload.
    ?assertEqual(
        {error, {message_too_large, 100}},
        livery_grpc_frame:decode_one(<<0, 0, 0, 0, 100>>, 10)
    ).

push_multiple_test() ->
    Bin = iolist_to_binary([
        livery_grpc_frame:encode(<<"a">>),
        livery_grpc_frame:encode(<<"bb">>, true),
        livery_grpc_frame:encode(<<"ccc">>)
    ]),
    {Frames, Buf} = livery_grpc_frame:push(Bin, livery_grpc_frame:new()),
    ?assertEqual([{false, <<"a">>}, {true, <<"bb">>}, {false, <<"ccc">>}], Frames),
    ?assert(livery_grpc_frame:is_empty(Buf)).

push_keeps_partial_test() ->
    Whole = iolist_to_binary(livery_grpc_frame:encode(<<"abcd">>)),
    <<Head:6/binary, Tail/binary>> = Whole,
    {F1, Buf1} = livery_grpc_frame:push(Head, livery_grpc_frame:new()),
    ?assertEqual([], F1),
    ?assertNot(livery_grpc_frame:is_empty(Buf1)),
    {F2, Buf2} = livery_grpc_frame:push(Tail, Buf1),
    ?assertEqual([{false, <<"abcd">>}], F2),
    ?assert(livery_grpc_frame:is_empty(Buf2)).

%%====================================================================
%% Properties
%%====================================================================

proper_test_() ->
    {timeout, 60, fun() ->
        ?assert(proper:quickcheck(prop_roundtrip(), [{to_file, user}, {numtests, 500}])),
        ?assert(proper:quickcheck(prop_fragmentation(), [{to_file, user}, {numtests, 500}]))
    end}.

%% A list of messages frames and re-decodes to the same list, flags intact.
prop_roundtrip() ->
    ?FORALL(
        Msgs,
        list({boolean(), binary()}),
        begin
            Bin = iolist_to_binary([livery_grpc_frame:encode(P, C) || {C, P} <- Msgs]),
            {Frames, Buf} = livery_grpc_frame:push(Bin, livery_grpc_frame:new()),
            Frames =:= Msgs andalso livery_grpc_frame:is_empty(Buf)
        end
    ).

%% Feeding the same byte stream in arbitrary chunk sizes yields the same
%% frames as feeding it whole. This is the streaming-decoder invariant.
prop_fragmentation() ->
    ?FORALL(
        {Msgs, ChunkSizes},
        {non_empty(list({boolean(), binary()})), list(pos_integer())},
        begin
            Bin = iolist_to_binary([livery_grpc_frame:encode(P, C) || {C, P} <- Msgs]),
            Chunks = split_bytes(Bin, ChunkSizes),
            {Frames, Buf} = feed(Chunks, livery_grpc_frame:new(), []),
            Frames =:= Msgs andalso livery_grpc_frame:is_empty(Buf)
        end
    ).

feed([], Buf, Acc) ->
    {lists:append(lists:reverse(Acc)), Buf};
feed([Chunk | Rest], Buf, Acc) ->
    {Frames, Buf1} = livery_grpc_frame:push(Chunk, Buf),
    feed(Rest, Buf1, [Frames | Acc]).

%% Slice Bin into pieces of the given sizes; any remainder is one last
%% piece so no bytes are dropped.
split_bytes(<<>>, _Sizes) ->
    [];
split_bytes(Bin, []) ->
    [Bin];
split_bytes(Bin, [Size | Rest]) ->
    case Bin of
        <<Head:Size/binary, Tail/binary>> -> [Head | split_bytes(Tail, Rest)];
        _ -> [Bin]
    end.
