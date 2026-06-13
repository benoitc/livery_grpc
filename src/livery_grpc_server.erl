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

This release implements unary and server-streaming. Client-streaming and
bidirectional dispatch arrive with the h2 bidi support they require.
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

-type server_opts() :: #{compression => livery_grpc_compression:algorithm()}.

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
            trailers_only(unimplemented, <<"method must be POST">>)
    end.

-spec dispatch_post(livery_req:req(), map(), server_opts()) -> livery_resp:resp().
dispatch_post(Req, Index, Opts) ->
    Ct = livery_req:header(<<"content-type">>, Req),
    case livery_grpc_codec:is_grpc_content_type(Ct) of
        false ->
            unsupported_media_type();
        true ->
            case maps:find(livery_req:path(Req), Index) of
                {ok, {Method, Handler}} ->
                    serve(Req, Method, Handler, Opts);
                error ->
                    trailers_only(unimplemented, <<"unknown method">>)
            end
    end.

-spec serve(livery_req:req(), livery_grpc_service:method(), module(), server_opts()) ->
    livery_resp:resp().
serve(Req, #{kind := unary} = Method, Handler, Opts) ->
    serve_unary(Req, Method, Handler, Opts);
serve(Req, #{kind := server_stream} = Method, Handler, Opts) ->
    serve_server_stream(Req, Method, Handler, Opts);
serve(_Req, #{kind := Kind}, _Handler, _Opts) when
    Kind =:= client_stream; Kind =:= bidi
->
    %% Needs h2 stream takeover; tracked by the h2 bidi contract.
    trailers_only(unimplemented, <<"streaming kind not yet supported">>).

%%====================================================================
%% Unary
%%====================================================================

-spec serve_unary(livery_req:req(), livery_grpc_service:method(), module(), server_opts()) ->
    livery_resp:resp().
serve_unary(Req, Method, Handler, Opts) ->
    case read_request_message(Req, Method) of
        {ok, Request} ->
            Ctx = ctx(Req, Method),
            Outcome = invoke_unary(Handler, Method, Request, Ctx),
            unary_response(Outcome, Method, Opts);
        {error, Status, Msg} ->
            trailers_only(Status, Msg)
    end.

-spec invoke_unary(module(), livery_grpc_service:method(), map() | tuple(), ctx()) ->
    callback_result().
invoke_unary(Handler, #{function := Fn}, Request, #{deadline := Deadline} = Ctx) ->
    Run = fun() ->
        try
            Handler:Fn(Request, Ctx)
        catch
            throw:{grpc_error, Status, Msg} -> {error, {Status, Msg}};
            Class:Reason:Stack -> {error, {internal, crash_message(Class, Reason, Stack)}}
        end
    end,
    with_deadline(Deadline, Run).

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

-spec unary_response(callback_result(), livery_grpc_service:method(), server_opts()) ->
    livery_resp:resp().
unary_response({ok, Reply}, Method, Opts) ->
    Frame = encode_message(Method, Reply, Opts),
    Producer = fun(Emit) -> Emit(Frame) end,
    ok_stream(Opts, Producer, ok);
unary_response({error, Status}, _Method, Opts) when is_atom(Status) ->
    ok_stream(Opts, fun(_Emit) -> ok end, {error, {Status, <<>>}});
unary_response({error, Error}, _Method, Opts) when is_tuple(Error) ->
    ok_stream(Opts, fun(_Emit) -> ok end, {error, Error}).

%%====================================================================
%% Server streaming
%%====================================================================

-spec serve_server_stream(
    livery_req:req(), livery_grpc_service:method(), module(), server_opts()
) ->
    livery_resp:resp().
serve_server_stream(Req, Method, Handler, Opts) ->
    case read_request_message(Req, Method) of
        {ok, Request} ->
            Ctx = ctx(Req, Method),
            Producer = server_stream_producer(Handler, Method, Request, Ctx, Opts),
            ok_stream(Opts, Producer, deferred);
        {error, Status, Msg} ->
            trailers_only(Status, Msg)
    end.

%% The producer drives the callback, handing it a `SendFun` that frames and
%% emits one reply at a time. The callback's final result decides the
%% trailers; it is stashed for the lazy trailers fun (see `ok_stream/2`).
-spec server_stream_producer(
    module(), livery_grpc_service:method(), map() | tuple(), ctx(), server_opts()
) ->
    fun((fun((iodata()) -> ok | {error, term()})) -> ok).
server_stream_producer(Handler, #{function := Fn} = Method, Request, Ctx, Opts) ->
    fun(Emit) ->
        SendFun = fun(Reply) -> Emit(encode_message(Method, Reply, Opts)) end,
        Outcome =
            try
                Handler:Fn(Request, SendFun, Ctx)
            catch
                throw:{grpc_error, S, M} -> {error, {S, M}};
                Class:Reason:Stack -> {error, {internal, crash_message(Class, Reason, Stack)}}
            end,
        stash_outcome(Outcome),
        ok
    end.

%%====================================================================
%% Response builders
%%====================================================================

%% A normal gRPC response: HTTP 200, gRPC content type, the producer's
%% frames, then status trailers. `Outcome` is either a concrete result
%% (`ok` / `{error, _}`) known up front, or `deferred` when the producer
%% stashes it at runtime (streaming).
-spec ok_stream(
    server_opts(), fun((term()) -> ok | {error, term()}), ok | deferred | {error, term()}
) ->
    livery_resp:resp().
ok_stream(Opts, Producer, Outcome) ->
    Resp = livery_resp:stream(200, response_headers(Opts), Producer),
    livery_resp:with_trailers(trailers_fun(Outcome), Resp).

-spec trailers_fun(ok | deferred | {error, term()}) ->
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

%% Trailers-Only: a single HEADERS block carrying the status. Built as an
%% empty-body response whose headers already include grpc-status, since
%% livery:emit/3 drops trailers on an empty body.
-spec trailers_only(livery_grpc_status:status(), binary()) -> livery_resp:resp().
trailers_only(Status, Msg) ->
    Headers = base_headers() ++ livery_grpc_status:trailers(Status, Msg),
    livery_resp:new(200, Headers, empty).

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
    case maps:get(compression, Opts, identity) of
        identity -> base_headers();
        gzip -> base_headers() ++ [{<<"grpc-encoding">>, <<"gzip">>}]
    end.

%%====================================================================
%% Message coding
%%====================================================================

%% Read the whole request body and decode the single expected message.
-spec read_request_message(livery_req:req(), livery_grpc_service:method()) ->
    {ok, map() | tuple()} | {error, livery_grpc_status:status(), binary()}.
read_request_message(Req, Method) ->
    case collect_body(livery_req:body(Req)) of
        {ok, Bin} -> decode_single(Bin, Req, Method);
        {error, Reason} -> {error, internal, reason_bin(Reason)}
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

-spec ctx(livery_req:req(), livery_grpc_service:method()) -> ctx().
ctx(Req, Method) ->
    #{
        metadata => metadata(Req),
        method => Method,
        deadline => livery_grpc_timeout:parse(livery_req:header(<<"grpc-timeout">>, Req)),
        req => Req
    }.

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
