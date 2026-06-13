-module(livery_grpc_frame).
-moduledoc """
gRPC length-prefixed message framing.

Each gRPC message on the wire is a `Length-Prefixed-Message`:

```
  Compressed-Flag (1 byte, 0 or 1) | Message-Length (4 bytes, big-endian) | Message
```

This module handles only the framing. Compression of the payload is
`livery_grpc_compression`; protobuf encode/decode is `livery_grpc_codec`.
The `Compressed-Flag` is surfaced as a boolean so the caller decides how
to interpret the payload.

For streaming, a frame can be split across several HTTP/2 DATA chunks. Use
a `buffer/0`: feed each inbound chunk to `push/2`, which returns every
whole frame it can now decode plus the leftover bytes for next time.
""".

-export([encode/1, encode/2]).
-export([new/0, push/2, push/3, is_empty/1]).
-export([decode_one/1, decode_one/2]).

-export_type([buffer/0, frame/0]).

%% A decoded frame: whether the payload is compressed, and the raw payload
%% bytes (still compressed if the flag is true).
-type frame() :: {Compressed :: boolean(), Payload :: binary()}.

%% Leftover bytes from a partial frame, carried between `push/2' calls.
-opaque buffer() :: binary().

%% 4-byte big-endian length field caps a single message at 4 GiB; gRPC
%% defaults to a far smaller limit, enforced via the `Max' argument.
-define(PREFIX_BYTES, 5).

%%====================================================================
%% Encoding
%%====================================================================

-doc "Frame an uncompressed payload.".
-spec encode(binary()) -> iodata().
encode(Payload) ->
    encode(Payload, false).

-doc """
Frame a payload, setting the compressed flag. The payload must already be
compressed when `Compressed` is `true`.
""".
-spec encode(binary(), boolean()) -> iodata().
encode(Payload, Compressed) when is_binary(Payload) ->
    Flag =
        case Compressed of
            true -> 1;
            false -> 0
        end,
    [<<Flag:8, (byte_size(Payload)):32/big>>, Payload].

%%====================================================================
%% Streaming decode
%%====================================================================

-doc "A fresh, empty decode buffer.".
-spec new() -> buffer().
new() ->
    <<>>.

-doc "Whether the buffer holds no leftover bytes.".
-spec is_empty(buffer()) -> boolean().
is_empty(<<>>) -> true;
is_empty(_) -> false.

-doc """
Append `Data` to the buffer and pull out every whole frame now available.

Returns `{Frames, Buffer}`: `Frames` is the list of complete frames in
arrival order, `Buffer` carries the trailing partial frame (if any). No
size limit is enforced; use `push/3` for that.
""".
-spec push(binary(), buffer()) -> {[frame()], buffer()}.
push(Data, Buffer) ->
    case push(Data, Buffer, infinity) of
        {ok, Frames, Buffer1} -> {Frames, Buffer1};
        {error, _} = E -> error(E)
    end.

-doc """
`push/2` with a per-message size ceiling (the decoded payload length).

Returns `{ok, Frames, Buffer}` or `{error, {message_too_large, Len}}` when
a frame's declared length exceeds `Max`. The ceiling is checked against
the length prefix before any payload is buffered, so an oversized frame is
rejected without reading its bytes.
""".
-spec push(binary(), buffer(), non_neg_integer() | infinity) ->
    {ok, [frame()], buffer()} | {error, {message_too_large, non_neg_integer()}}.
push(Data, Buffer, Max) ->
    decode_loop(<<Buffer/binary, Data/binary>>, Max, []).

-spec decode_loop(binary(), non_neg_integer() | infinity, [frame()]) ->
    {ok, [frame()], buffer()} | {error, {message_too_large, non_neg_integer()}}.
decode_loop(Bin, Max, Acc) ->
    case Bin of
        <<_Flag:8, Len:32/big, _/binary>> when Max =/= infinity, Len > Max ->
            {error, {message_too_large, Len}};
        <<Flag:8, Len:32/big, Payload:Len/binary, Rest/binary>> ->
            decode_loop(Rest, Max, [{Flag =:= 1, Payload} | Acc]);
        _Partial ->
            {ok, lists:reverse(Acc), Bin}
    end.

%%====================================================================
%% Single-frame decode
%%====================================================================

-doc "Decode exactly one frame, returning the rest. See `decode_one/2`.".
-spec decode_one(binary()) ->
    {ok, frame(), binary()} | more | {error, {message_too_large, non_neg_integer()}}.
decode_one(Bin) ->
    decode_one(Bin, infinity).

-doc """
Decode one frame from the front of `Bin`.

`{ok, Frame, Rest}` on a whole frame, `more` when more bytes are needed,
`{error, {message_too_large, Len}}` when the declared length exceeds `Max`.
""".
-spec decode_one(binary(), non_neg_integer() | infinity) ->
    {ok, frame(), binary()} | more | {error, {message_too_large, non_neg_integer()}}.
decode_one(<<_Flag:8, Len:32/big, _/binary>>, Max) when Max =/= infinity, Len > Max ->
    {error, {message_too_large, Len}};
decode_one(<<Flag:8, Len:32/big, Payload:Len/binary, Rest/binary>>, _Max) ->
    {ok, {Flag =:= 1, Payload}, Rest};
decode_one(_Bin, _Max) ->
    more.
