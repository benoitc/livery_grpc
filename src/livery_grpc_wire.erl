-module(livery_grpc_wire).
-moduledoc """
Message <-> wire glue shared by the server and the client.

Combines the three wire concerns into one place: protobuf coding
(`livery_grpc_codec`), per-message compression (`livery_grpc_compression`),
and length-prefixed framing (`livery_grpc_frame`). The server and client
encode and decode messages through here so the rules stay identical on
both sides.
""".

-export([encode/4, decode_frame/4, decode_all/5]).

-doc """
Encode one message to a wire frame: protobuf-encode, compress with
`Algorithm`, then length-prefix.
""".
-spec encode(module(), atom(), map() | tuple(), livery_grpc_compression:algorithm()) ->
    {ok, iodata()} | {error, {encode, term()}}.
encode(Proto, MsgName, Msg, Algorithm) ->
    case livery_grpc_codec:encode(Proto, MsgName, Msg) of
        {ok, Bin} ->
            {Compressed, Bytes} = livery_grpc_compression:compress(Algorithm, Bin),
            {ok, livery_grpc_frame:encode(Bytes, Compressed)};
        {error, _} = E ->
            E
    end.

-doc """
Decode one framed message: decompress per the frame flag and message
`Encoding`, then protobuf-decode as `MsgName`.
""".
-spec decode_frame(
    module(), atom(), livery_grpc_compression:algorithm(), livery_grpc_frame:frame()
) ->
    {ok, map() | tuple()} | {error, term()}.
decode_frame(Proto, MsgName, Encoding, {Compressed, Payload}) ->
    try livery_grpc_compression:decompress(Compressed, Encoding, Payload) of
        Raw -> livery_grpc_codec:decode(Proto, MsgName, Raw)
    catch
        error:{grpc_compression, _} = Reason -> {error, Reason}
    end.

-doc """
Decode every whole frame in `Bin` as `MsgName`. Returns `{error,
incomplete}` if a trailing partial frame remains, or the first frame's
decode error. `Max` caps a single message's declared length.
""".
-spec decode_all(
    module(), atom(), livery_grpc_compression:algorithm(), binary(), non_neg_integer() | infinity
) ->
    {ok, [map() | tuple()]} | {error, term()}.
decode_all(Proto, MsgName, Encoding, Bin, Max) ->
    case livery_grpc_frame:push(Bin, livery_grpc_frame:new(), Max) of
        {ok, Frames, Buf} ->
            case livery_grpc_frame:is_empty(Buf) of
                true -> decode_each(Proto, MsgName, Encoding, Frames, []);
                false -> {error, incomplete}
            end;
        {error, _} = E ->
            E
    end.

-spec decode_each(
    module(), atom(), livery_grpc_compression:algorithm(), [livery_grpc_frame:frame()], [
        map() | tuple()
    ]
) ->
    {ok, [map() | tuple()]} | {error, term()}.
decode_each(_Proto, _MsgName, _Encoding, [], Acc) ->
    {ok, lists:reverse(Acc)};
decode_each(Proto, MsgName, Encoding, [Frame | Rest], Acc) ->
    case decode_frame(Proto, MsgName, Encoding, Frame) of
        {ok, Msg} -> decode_each(Proto, MsgName, Encoding, Rest, [Msg | Acc]);
        {error, _} = E -> E
    end.
