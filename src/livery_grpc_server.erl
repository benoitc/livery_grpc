-module(livery_grpc_server).
-moduledoc """
gRPC request dispatch for a livery handler.

`handler/2` turns a routing index (path -> `{method, callback module}`)
into a `fun((livery_req:req()) -> livery_resp:resp())` that a dedicated
gRPC h2 listener runs for every request. It:

1. Validates the request is gRPC (`POST` with an `application/grpc`
   content type) and matches the `:path` to a method.
2. Reads the request frames from the body, decompresses and decodes them
   into protobuf messages.
3. Invokes the callback (`Handler:Function(...)`) for the method's call
   kind.
4. Writes response frames and ends the stream with `grpc-status` (and an
   optional `grpc-message`) in the trailers.

Every gRPC response is HTTP 200; the call outcome travels in the
trailers, per the gRPC-over-HTTP/2 spec. A request that fails before
dispatch (wrong content type, unknown method) gets a Trailers-Only reply:
a single HEADERS block carrying the status.

All four call kinds are supported. Client-streaming and bidirectional
read requests through a `livery_grpc_stream` handle and (for bidi) send
replies through it, interleaved, inside the chunked response producer.
""".

-export([handler/1, handler/2]).

-export_type([ctx/0, callback_result/0, server_opts/0]).

%% The context handed to every callback. Carries the call metadata (the
%% request's custom headers), the method descriptor, and the underlying
%% request value for adapter-level needs (peer, disconnect, deadline).
-type ctx() :: #{
    metadata := [{binary(), binary()}],
    method := livery_grpc_service:method(),
    %% The call deadline in milliseconds from grpc-timeout, or `infinity`.
    deadline := timeout(),
    %% Reflection data, present only for the reflection service.
    reflection => term(),
    req := livery_req:req()
}.

%% A unary callback returns a reply or an error status. A streaming
%% callback returns `ok` or an error status once it has finished sending.
%% An error may carry a message and optional binary details (an encoded
%% google.rpc.Status), surfaced as grpc-status-details-bin.
-type callback_result() ::
    {ok, map() | tuple()}
    | ok
    | {error, livery_grpc_status:status()}
    | {error, {livery_grpc_status:status(), binary()}}
    | {error, {livery_grpc_status:status(), binary(), binary()}}.

-type server_opts() :: #{
    compression => livery_grpc_compression:algorithm(),
    reflection => term()
}.

-define(CONTENT_TYPE, <<"application/grpc+proto">>).
%% Cap a single inbound request message (16 MiB), matching livery's body
%% default. Configurable later alongside deadlines.
-define(MAX_RECV, 16 * 1024 * 1024).

%%====================================================================
%% Handler construction
%%====================================================================

-doc "`handler/2` with default options.".
-spec handler(#{binary() => {livery_grpc_service:method(), module()}}) ->
    fun((livery_req:req()) -> livery_resp:resp()).
handler(Index) ->
    handler(Index, #{}).

-doc """
Build the gRPC request handler from a routing index.

`Index` maps a wire path to `{Method, Handler}` (see
`livery_grpc_service:index/1`). `Opts` may set `compression` for the
outbound encoding (default `identity`).
""".
-spec handler(#{binary() => {livery_grpc_service:method(), module()}}, server_opts()) ->
    fun((livery_req:req()) -> livery_resp:resp()).
handler(Index, Opts) when is_map(Index) ->
    fun(Req) -> dispatch(Req, Index, Opts) end.

%%====================================================================
%% Dispatch
%%====================================================================

-spec dispatch(livery_req:req(), map(), server_opts()) -> livery_resp:resp().
dispatch(Req, Index, Opts) ->
    case livery_req:method(Req) of
        <<"POST">> ->
            dispatch_post(Req, Index, Opts);
        _ ->
            %% gRPC is POST-only; anything else is not a gRPC call.
            error_response(unimplemented, <<"method must be POST">>, grpc)
    end.

-spec dispatch_post(livery_req:req(), map(), server_opts()) -> livery_resp:resp().
dispatch_post(Req, Index, Opts) ->
    Ct = livery_req:header(<<"content-type">>, Req),
    case livery_grpc_web:mode(Ct) of
        undefined ->
            unsupported_media_type();
        Mode ->
            case maps:find(livery_req:path(Req), Index) of
                {ok, {Method, Handler}} ->
                    serve(Req, Method, Handler, Opts, Mode);
                error ->
                    error_response(unimplemented, <<"unknown method">>, Mode)
            end
    end.

-spec serve(
    livery_req:req(), livery_grpc_service:method(), module(), server_opts(), livery_grpc_web:mode()
) ->
    livery_resp:resp().
serve(Req, #{kind := unary} = Method, Handler, Opts, Mode) ->
    serve_unary(Req, Method, Handler, Opts, Mode);
serve(Req, #{kind := server_stream} = Method, Handler, Opts, Mode) ->
    serve_server_stream(Req, Method, Handler, Opts, Mode);
serve(Req, #{kind := client_stream} = Method, Handler, Opts, grpc) ->
    serve_client_stream(Req, Method, Handler, Opts);
serve(Req, #{kind := bidi} = Method, Handler, Opts, grpc) ->
    serve_bidi(Req, Method, Handler, Opts);
serve(_Req, #{kind := Kind}, _Handler, _Opts, Mode) when
    Kind =:= client_stream; Kind =:= bidi
->
    %% gRPC-Web has no request streaming; these need full HTTP/2.
    error_response(unimplemented, <<"client-streaming requires gRPC over HTTP/2">>, Mode).

%%====================================================================
%% Unary
%%====================================================================

-spec serve_unary(
    livery_req:req(), livery_grpc_service:method(), module(), server_opts(), livery_grpc_web:mode()
) ->
    livery_resp:resp().
serve_unary(Req, Method, Handler, Opts, Mode) ->
    case read_request_message(Req, Method, Mode) of
        {ok, Request} ->
            Ctx = ctx(Req, Method, Opts),
            Outcome = invoke_unary(Handler, Method, Request, Ctx),
            unary_response(Outcome, Method, Opts, Mode);
        {error, Status, Msg} ->
            error_response(Status, Msg, Mode)
    end.

-spec invoke_unary(module(), livery_grpc_service:method(), map() | tuple(), ctx()) ->
    callback_result().
invoke_unary(Handler, #{function := Fn}, Request, #{deadline := Deadline} = Ctx) ->
    with_deadline(Deadline, fun() -> guard_call(fun() -> Handler:Fn(Request, Ctx) end) end).

%% Run a callback, turning a thrown grpc_error or any crash into an error
%% result with the right gRPC status.
-spec guard_call(fun(() -> callback_result())) -> callback_result().
guard_call(Fun) ->
    try
        Fun()
    catch
        throw:{grpc_error, Status, Msg} -> {error, {Status, Msg}};
        Class:Reason:Stack -> {error, {internal, crash_message(Class, Reason, Stack)}}
    end.

%% Enforce a unary call deadline by running the handler in a monitored
%% child and killing it if the deadline passes. `infinity` runs inline.
-spec with_deadline(timeout(), fun(() -> callback_result())) -> callback_result().
with_deadline(infinity, Run) ->
    Run();
with_deadline(Ms, Run) ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, MRef} = spawn_monitor(fun() -> Parent ! {Ref, Run()} end),
    receive
        {Ref, Result} ->
            erlang:demonitor(MRef, [flush]),
            Result;
        {'DOWN', MRef, process, Pid, Reason} ->
            {error, {internal, reason_bin(Reason)}}
    after Ms ->
        erlang:demonitor(MRef, [flush]),
        exit(Pid, kill),
        {error, {deadline_exceeded, <<"deadline exceeded">>}}
    end.

%% Build the response for a unary outcome, in grpc or gRPC-Web framing.
-spec unary_response(
    callback_result(), livery_grpc_service:method(), server_opts(), livery_grpc_web:mode()
) ->
    livery_resp:resp().
unary_response(Outcome, Method, Opts, grpc) ->
    unary_grpc_response(normalize_outcome(Outcome), Method, Opts);
unary_response(Outcome, Method, Opts, Mode) ->
    Frames = outcome_frames(normalize_outcome(Outcome), Method, Opts),
    web_response(Mode, Opts, Frames, normalize_outcome(Outcome)).

-spec unary_grpc_response(
    ok | {ok, map() | tuple()} | {error, term()}, livery_grpc_service:method(), server_opts()
) ->
    livery_resp:resp().
unary_grpc_response({ok, Reply}, Method, Opts) ->
    Frame = encode_message(Method, Reply, Opts),
    ok_stream(Opts, fun(Emit) -> Emit(Frame) end, {ok, Reply});
unary_grpc_response({error, _} = Error, _Method, Opts) ->
    ok_stream(Opts, fun(_Emit) -> ok end, Error).

%% The message frames a successful outcome contributes (none on error).
-spec outcome_frames(
    ok | {ok, map() | tuple()} | {error, term()}, livery_grpc_service:method(), server_opts()
) ->
    [iodata()].
outcome_frames({ok, Reply}, Method, Opts) -> [encode_message(Method, Reply, Opts)];
outcome_frames({error, _}, _Method, _Opts) -> [].

%% Normalise the bare-atom error form so the rest of the path sees a tuple.
-spec normalize_outcome(callback_result()) -> ok | {ok, map() | tuple()} | {error, term()}.
normalize_outcome({error, Status}) when is_atom(Status) -> {error, {Status, <<>>}};
normalize_outcome(Other) -> Other.

%%====================================================================
%% Server streaming
%%====================================================================

-spec serve_server_stream(
    livery_req:req(), livery_grpc_service:method(), module(), server_opts(), livery_grpc_web:mode()
) ->
    livery_resp:resp().
serve_server_stream(Req, Method, Handler, Opts, Mode) ->
    case read_request_message(Req, Method, Mode) of
        {ok, Request} ->
            Ctx = ctx(Req, Method, Opts),
            server_stream_response(Mode, Handler, Method, Request, Ctx, Opts);
        {error, Status, Msg} ->
            error_response(Status, Msg, Mode)
    end.

-spec server_stream_response(
    livery_grpc_web:mode(),
    module(),
    livery_grpc_service:method(),
    map() | tuple(),
    ctx(),
    server_opts()
) ->
    livery_resp:resp().
server_stream_response(grpc, Handler, Method, Request, Ctx, Opts) ->
    %% Stream frames as they come; the callback's outcome becomes the
    %% HTTP trailers (stashed for the lazy trailers fun).
    Producer = fun(Emit) ->
        SendFun = fun(Reply) -> Emit(encode_message(Method, Reply, Opts)) end,
        stash_outcome(invoke_server_stream(Handler, Method, Request, Ctx, SendFun)),
        ok
    end,
    ok_stream(Opts, Producer, deferred);
server_stream_response(grpc_web, Handler, Method, Request, Ctx, Opts) ->
    %% Binary gRPC-Web: stream frames, then a trailer frame; no HTTP trailers.
    Producer = fun(Emit) ->
        SendFun = fun(Reply) -> Emit(encode_message(Method, Reply, Opts)) end,
        Outcome = invoke_server_stream(Handler, Method, Request, Ctx, SendFun),
        Emit(livery_grpc_web:trailer_frame(outcome_trailers(Outcome))),
        ok
    end,
    livery_resp:stream(200, web_headers(grpc_web, Opts), Producer);
server_stream_response(grpc_web_text, Handler, Method, Request, Ctx, Opts) ->
    %% Text gRPC-Web base64s the whole body, so collect frames first.
    {Frames, Outcome} = collect_server_stream(Handler, Method, Request, Ctx, Opts),
    web_response(grpc_web_text, Opts, Frames, Outcome).

-spec invoke_server_stream(
    module(), livery_grpc_service:method(), map() | tuple(), ctx(), fun((map() | tuple()) -> term())
) ->
    ok | {error, term()}.
invoke_server_stream(Handler, #{function := Fn}, Request, Ctx, SendFun) ->
    guard_call(fun() -> Handler:Fn(Request, SendFun, Ctx) end).

%% Run a server-streaming callback, gathering its frames into a list (for
%% the text variant, which cannot stream).
-spec collect_server_stream(
    module(), livery_grpc_service:method(), map() | tuple(), ctx(), server_opts()
) ->
    {[iodata()], ok | {error, term()}}.
collect_server_stream(Handler, Method, Request, Ctx, Opts) ->
    Ref = make_ref(),
    Self = self(),
    SendFun = fun(Reply) -> Self ! {Ref, encode_message(Method, Reply, Opts)} end,
    Outcome = invoke_server_stream(Handler, Method, Request, Ctx, SendFun),
    {drain_frames(Ref, []), Outcome}.

-spec drain_frames(reference(), [iodata()]) -> [iodata()].
drain_frames(Ref, Acc) ->
    receive
        {Ref, Frame} -> drain_frames(Ref, [Frame | Acc])
    after 0 -> lists:reverse(Acc)
    end.

%%====================================================================
%% Client streaming and bidirectional
%%====================================================================

%% Client-streaming: the callback reads every request via the stream and
%% returns one reply, so the response is shaped like a unary reply.
-spec serve_client_stream(
    livery_req:req(), livery_grpc_service:method(), module(), server_opts()
) ->
    livery_resp:resp().
serve_client_stream(Req, #{function := Fn} = Method, Handler, Opts) ->
    Stream = livery_grpc_stream:reader(Req, Method),
    Ctx = ctx(Req, Method, Opts),
    Outcome = guard_call(fun() -> Handler:Fn(Stream, Ctx) end),
    unary_response(Outcome, Method, Opts, grpc).

%% Bidirectional: the callback reads requests and sends replies through the
%% stream, interleaved, inside the chunked producer. Its result becomes the
%% trailers.
-spec serve_bidi(livery_req:req(), livery_grpc_service:method(), module(), server_opts()) ->
    livery_resp:resp().
serve_bidi(Req, #{function := Fn} = Method, Handler, Opts) ->
    Compression = maps:get(compression, Opts, identity),
    Producer = fun(Emit) ->
        Stream = livery_grpc_stream:bidi(Req, Method, Emit, Compression),
        Ctx = ctx(Req, Method, Opts),
        stash_outcome(guard_call(fun() -> Handler:Fn(Stream, Ctx) end)),
        ok
    end,
    ok_stream(Opts, Producer, deferred).

%%====================================================================
%% Response builders
%%====================================================================

%% A normal gRPC response: HTTP 200, gRPC content type, the producer's
%% frames, then status trailers. `Outcome` is either a concrete result
%% (`ok` / `{error, _}`) known up front, or `deferred` when the producer
%% stashes it at runtime (streaming).
-spec ok_stream(
    server_opts(),
    fun((term()) -> ok | {error, term()}),
    ok | deferred | {ok, map() | tuple()} | {error, term()}
) ->
    livery_resp:resp().
ok_stream(Opts, Producer, Outcome) ->
    Resp = livery_resp:stream(200, response_headers(Opts), Producer),
    livery_resp:with_trailers(trailers_fun(Outcome), Resp).

-spec trailers_fun(ok | deferred | {ok, map() | tuple()} | {error, term()}) ->
    fun(() -> [{binary(), binary()}]).
trailers_fun(deferred) ->
    fun() -> outcome_trailers(take_outcome()) end;
trailers_fun(Outcome) ->
    fun() -> outcome_trailers(Outcome) end.

-spec outcome_trailers(term()) -> [{binary(), binary()}].
outcome_trailers(ok) ->
    livery_grpc_status:trailers(ok);
outcome_trailers({ok, _Reply}) ->
    livery_grpc_status:trailers(ok);
outcome_trailers({error, {Status, Msg}}) ->
    livery_grpc_status:trailers(Status, Msg);
outcome_trailers({error, {Status, Msg, Details}}) ->
    livery_grpc_status:trailers(Status, Msg) ++
        [{<<"grpc-status-details-bin">>, base64:encode(Details)}];
outcome_trailers({error, Status}) when is_atom(Status) ->
    livery_grpc_status:trailers(Status);
outcome_trailers(_Other) ->
    livery_grpc_status:trailers(internal, <<"invalid handler result">>).

%% An error before/without message frames, in the right framing for the
%% mode. grpc uses a Trailers-Only reply (status in the HEADERS block,
%% which livery:emit/3 keeps only because the body is empty); gRPC-Web puts
%% the status in a trailer frame in the body.
-spec error_response(livery_grpc_status:status(), binary(), livery_grpc_web:mode()) ->
    livery_resp:resp().
error_response(Status, Msg, grpc) ->
    Headers = base_headers() ++ livery_grpc_status:trailers(Status, Msg),
    livery_resp:new(200, Headers, empty);
error_response(Status, Msg, Mode) ->
    web_response(Mode, #{}, [], {error, {Status, Msg}}).

%% A full gRPC-Web response: message frames followed by the trailer frame,
%% base64-encoded for the text variant.
-spec web_response(
    livery_grpc_web:mode(), server_opts(), [iodata()], ok | {ok, term()} | {error, term()}
) ->
    livery_resp:resp().
web_response(Mode, Opts, Frames, Outcome) ->
    Trailer = livery_grpc_web:trailer_frame(outcome_trailers(Outcome)),
    Body = livery_grpc_web:encode_body(Mode, [Frames, Trailer]),
    livery_resp:new(200, web_headers(Mode, Opts), {full, Body}).

-spec unsupported_media_type() -> livery_resp:resp().
unsupported_media_type() ->
    livery_resp:text(415, <<"content-type must be application/grpc">>).

-spec base_headers() -> [{binary(), binary()}].
base_headers() ->
    [{<<"content-type">>, ?CONTENT_TYPE}].

%% Response headers for a message-bearing reply: advertise the response
%% encoding when the server compresses. (Honoring the client's
%% grpc-accept-encoding is a later refinement.)
-spec response_headers(server_opts()) -> [{binary(), binary()}].
response_headers(Opts) ->
    maybe_encoding(Opts, base_headers()).

-spec web_headers(livery_grpc_web:mode(), server_opts()) -> [{binary(), binary()}].
web_headers(Mode, Opts) ->
    maybe_encoding(Opts, [{<<"content-type">>, livery_grpc_web:content_type(Mode)}]).

-spec maybe_encoding(server_opts(), [{binary(), binary()}]) -> [{binary(), binary()}].
maybe_encoding(Opts, Headers) ->
    case maps:get(compression, Opts, identity) of
        identity -> Headers;
        gzip -> Headers ++ [{<<"grpc-encoding">>, <<"gzip">>}]
    end.

%%====================================================================
%% Message coding
%%====================================================================

%% Read the whole request body and decode the single expected message.
%% For the gRPC-Web text variant the body is base64 first.
-spec read_request_message(
    livery_req:req(), livery_grpc_service:method(), livery_grpc_web:mode()
) ->
    {ok, map() | tuple()} | {error, livery_grpc_status:status(), binary()}.
read_request_message(Req, Method, Mode) ->
    case collect_body(livery_req:body(Req)) of
        {ok, Bin} ->
            try livery_grpc_web:decode_request(Mode, Bin) of
                Decoded -> decode_single(Decoded, Req, Method)
            catch
                error:_ -> {error, internal, <<"bad base64 request body">>}
            end;
        {error, Reason} ->
            {error, internal, reason_bin(Reason)}
    end.

-spec collect_body(empty | {buffered, iodata()} | {stream, term()}) ->
    {ok, binary()} | {error, term()}.
collect_body(empty) ->
    {ok, <<>>};
collect_body({buffered, IoData}) ->
    {ok, iolist_to_binary(IoData)};
collect_body({stream, Reader}) ->
    case livery_body:read_all(Reader, 30000, ?MAX_RECV) of
        {ok, Bin, _Reader} -> {ok, Bin};
        {error, Reason, _Reader} -> {error, Reason}
    end.

-spec decode_single(binary(), livery_req:req(), livery_grpc_service:method()) ->
    {ok, map() | tuple()} | {error, livery_grpc_status:status(), binary()}.
decode_single(Bin, Req, #{proto := Proto, input := Input}) ->
    case livery_grpc_frame:push(Bin, livery_grpc_frame:new(), ?MAX_RECV) of
        {ok, [{Compressed, Payload}] = _One, Buf} ->
            case livery_grpc_frame:is_empty(Buf) of
                true -> decode_payload(Compressed, Payload, Req, Proto, Input);
                false -> {error, internal, <<"trailing bytes after request message">>}
            end;
        {ok, [], _Buf} ->
            {error, internal, <<"empty request">>};
        {ok, _Many, _Buf} ->
            {error, internal, <<"expected a single request message">>};
        {error, {message_too_large, _}} ->
            {error, resource_exhausted, <<"request message too large">>}
    end.

-spec decode_payload(boolean(), binary(), livery_req:req(), module(), atom()) ->
    {ok, map() | tuple()} | {error, livery_grpc_status:status(), binary()}.
decode_payload(Compressed, Payload, Req, Proto, Input) ->
    Encoding = livery_grpc_compression:from_header(
        livery_req:header(<<"grpc-encoding">>, Req)
    ),
    case livery_grpc_wire:decode_frame(Proto, Input, Encoding, {Compressed, Payload}) of
        {ok, Msg} -> {ok, Msg};
        {error, {grpc_compression, _}} -> {error, internal, <<"bad message compression">>};
        {error, _} -> {error, internal, <<"could not decode request">>}
    end.

%% Encode, compress, and frame one reply message.
-spec encode_message(livery_grpc_service:method(), map() | tuple(), server_opts()) ->
    iodata().
encode_message(#{proto := Proto, output := Output}, Reply, Opts) ->
    Algorithm = maps:get(compression, Opts, identity),
    {ok, Frame} = livery_grpc_wire:encode(Proto, Output, Reply, Algorithm),
    Frame.

%%====================================================================
%% Context and helpers
%%====================================================================

-spec ctx(livery_req:req(), livery_grpc_service:method(), server_opts()) -> ctx().
ctx(Req, Method, Opts) ->
    Base = #{
        metadata => metadata(Req),
        method => Method,
        deadline => livery_grpc_timeout:parse(livery_req:header(<<"grpc-timeout">>, Req)),
        req => Req
    },
    case maps:find(reflection, Opts) of
        {ok, Data} -> Base#{reflection => Data};
        error -> Base
    end.

%% Call metadata is the request's custom headers: drop the HTTP and gRPC
%% framing headers, keep what the application sent.
-spec metadata(livery_req:req()) -> [{binary(), binary()}].
metadata(Req) ->
    [{N, V} || {N, V} <- livery_req:headers(Req), not reserved_header(N)].

-spec reserved_header(binary()) -> boolean().
reserved_header(<<":", _/binary>>) -> true;
reserved_header(<<"content-type">>) -> true;
reserved_header(<<"grpc-encoding">>) -> true;
reserved_header(<<"grpc-accept-encoding">>) -> true;
reserved_header(<<"grpc-timeout">>) -> true;
reserved_header(<<"te">>) -> true;
reserved_header(<<"user-agent">>) -> true;
reserved_header(_) -> false.

%% Stash/take the streaming outcome via a self-message keyed by a fixed
%% tag. The producer and the trailers fun run in the same worker process,
%% in order (producer first), so the message is waiting when trailers run.
-spec stash_outcome(term()) -> ok.
stash_outcome(Outcome) ->
    self() ! {grpc_stream_outcome, Outcome},
    ok.

-spec take_outcome() -> term().
take_outcome() ->
    receive
        {grpc_stream_outcome, Outcome} -> Outcome
    after 0 -> {error, {internal, <<"missing stream outcome">>}}
    end.

-spec crash_message(atom(), term(), list()) -> binary().
crash_message(Class, Reason, _Stack) ->
    iolist_to_binary(io_lib:format("handler ~s: ~p", [Class, Reason])).

-spec reason_bin(term()) -> binary().
reason_bin(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).
