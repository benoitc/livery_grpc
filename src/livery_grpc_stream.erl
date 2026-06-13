-module(livery_grpc_stream).
-moduledoc """
A server-side stream handle for client-streaming and bidirectional RPCs.

The handle wraps the request body as a sequence of decoded messages
(`recv/1`, `recv_all/1`) and, for bidirectional calls, a `send/2` that
frames and emits a reply. Both run in the request worker: request DATA
arrives through livery's body reader and replies go out through the
chunked-response emitter, so a handler can read and write on the one
stream by interleaving `recv/1` and `send/2`.

`recv/1` threads the handle (it advances a frame buffer), the way
`livery_body:read/2` threads its reader.
""".

-export([reader/2, bidi/4]).
-export([recv/1, recv_all/1, send/2]).

-export_type([stream/0]).

-opaque stream() :: #{
    reader := livery_body:reader() | done,
    buffer := binary(),
    proto := module(),
    input := atom(),
    output := atom(),
    encoding := livery_grpc_compression:algorithm(),
    %% Reply emitter for bidirectional calls; `undefined` for
    %% client-streaming (which returns a single reply instead).
    emit := fun((iodata()) -> ok | {error, term()}) | undefined,
    compression := livery_grpc_compression:algorithm()
}.

-define(RECV_TIMEOUT, 30000).
-define(MAX_RECV, 16 * 1024 * 1024).

%%====================================================================
%% Construction
%%====================================================================

-doc "A receive-only handle (client-streaming).".
-spec reader(livery_req:req(), livery_grpc_service:method()) -> stream().
reader(Req, Method) ->
    new(Req, Method, undefined, identity).

-doc "A bidirectional handle: receive requests and send replies.".
-spec bidi(
    livery_req:req(),
    livery_grpc_service:method(),
    fun((iodata()) -> ok | {error, term()}),
    livery_grpc_compression:algorithm()
) -> stream().
bidi(Req, Method, Emit, Compression) ->
    new(Req, Method, Emit, Compression).

-spec new(
    livery_req:req(),
    livery_grpc_service:method(),
    fun((iodata()) -> ok | {error, term()}) | undefined,
    livery_grpc_compression:algorithm()
) -> stream().
new(Req, #{proto := Proto, input := Input, output := Output}, Emit, Compression) ->
    #{
        reader => body_reader(livery_req:body(Req)),
        buffer => <<>>,
        proto => Proto,
        input => Input,
        output => Output,
        encoding => livery_grpc_compression:from_header(
            livery_req:header(<<"grpc-encoding">>, Req)
        ),
        emit => Emit,
        compression => Compression
    }.

-spec body_reader(empty | {buffered, iodata()} | {stream, term()}) ->
    livery_body:reader() | done.
body_reader({stream, Reader}) -> Reader;
body_reader(_EmptyOrBuffered) -> done.

%%====================================================================
%% Receiving
%%====================================================================

-doc """
Receive the next request message. `{ok, Msg, Stream}` for a message,
`{eof, Stream}` once the client has half-closed and the buffer is drained,
or `{error, Reason, Stream}`.
""".
-spec recv(stream()) ->
    {ok, map() | tuple(), stream()} | {eof, stream()} | {error, term(), stream()}.
recv(#{buffer := Buffer} = Stream) ->
    case livery_grpc_frame:decode_one(Buffer, ?MAX_RECV) of
        {ok, Frame, Rest} ->
            decode(Frame, Stream#{buffer => Rest});
        more ->
            fill(Stream);
        {error, Reason} ->
            {error, Reason, Stream}
    end.

%% Pull more body bytes when the buffer holds no whole frame.
-spec fill(stream()) ->
    {ok, map() | tuple(), stream()} | {eof, stream()} | {error, term(), stream()}.
fill(#{reader := done, buffer := <<>>} = Stream) ->
    {eof, Stream};
fill(#{reader := done} = Stream) ->
    %% Bytes left over but the body ended: a truncated frame.
    {error, incomplete, Stream};
fill(#{reader := Reader, buffer := Buffer} = Stream) ->
    case livery_body:read(Reader, ?RECV_TIMEOUT) of
        {ok, Chunk, Reader1} ->
            recv(Stream#{reader => Reader1, buffer => <<Buffer/binary, Chunk/binary>>});
        {done, Reader1} ->
            recv(Stream#{reader => done_after(Reader1)});
        {error, Reason, _Reader1} ->
            {error, Reason, Stream}
    end.

%% After the body reader reports done, mark the stream done so the next
%% empty-buffer recv returns eof.
-spec done_after(livery_body:reader()) -> done.
done_after(_Reader) -> done.

-spec decode(livery_grpc_frame:frame(), stream()) ->
    {ok, map() | tuple(), stream()} | {error, term(), stream()}.
decode(Frame, #{proto := Proto, input := Input, encoding := Encoding} = Stream) ->
    case livery_grpc_wire:decode_frame(Proto, Input, Encoding, Frame) of
        {ok, Msg} -> {ok, Msg, Stream};
        {error, Reason} -> {error, Reason, Stream}
    end.

-doc "Receive every remaining request message into a list.".
-spec recv_all(stream()) -> {ok, [map() | tuple()], stream()} | {error, term(), stream()}.
recv_all(Stream) ->
    recv_all(Stream, []).

-spec recv_all(stream(), [map() | tuple()]) ->
    {ok, [map() | tuple()], stream()} | {error, term(), stream()}.
recv_all(Stream, Acc) ->
    case recv(Stream) of
        {ok, Msg, Stream1} -> recv_all(Stream1, [Msg | Acc]);
        {eof, Stream1} -> {ok, lists:reverse(Acc), Stream1};
        {error, Reason, Stream1} -> {error, Reason, Stream1}
    end.

%%====================================================================
%% Sending (bidirectional)
%%====================================================================

-doc "Frame and send one reply message (bidirectional calls only).".
-spec send(stream(), map() | tuple()) -> ok | {error, term()}.
send(#{emit := undefined}, _Msg) ->
    {error, not_bidirectional};
send(#{emit := Emit, proto := Proto, output := Output, compression := Compression}, Msg) ->
    case livery_grpc_wire:encode(Proto, Output, Msg, Compression) of
        {ok, Frame} -> Emit(Frame);
        {error, _} = E -> E
    end.
