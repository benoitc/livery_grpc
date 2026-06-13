-module(livery_grpc_client).
-moduledoc """
gRPC client over the livery `h2` client.

Open a connection with `connect/2,3`, then call methods. A call reads like
`erpc`: hand it a method descriptor and a request message, get a reply
back.

```erlang
{ok, Conn} = livery_grpc_client:connect("localhost", 50051),
{ok, M} = livery_grpc_client:method(helloworld_pb, 'Greeter', 'SayHello'),
{ok, #{message := Msg}} = livery_grpc_client:call(Conn, M, #{name => <<"ada">>}),
ok = livery_grpc_client:close(Conn).
```

The connection's events are delivered to the process that called
`connect/2,3`, so make calls from that same process. Calls are
synchronous: each one drives its stream to completion before returning.

`call/3,4` handles unary (`{ok, Reply}`) and server-streaming (`{ok,
[Reply]}`). For client-streaming use `client_stream/3,4`; for
bidirectional (or fine-grained control) use `open/2,3` then `send/2`,
`send_end/1`, and `recv/1,2`.

Calls compose through an interceptor stack, the outbound twin of livery's
server middleware (Tower layers on the BEAM). Pass `interceptors` to
`connect/3` (per connection) or to a call's options (per call); each entry
is `{Module, State}` or `fun((Request, Next) -> Result)`, the same shape
as `livery_client` layers. `before/1`, `after_response/1`, and `wrap/1`
build common ones.
""".

-export([connect/2, connect/3, close/1]).
-export([method/3]).
-export([call/3, call/4]).
-export([client_stream/3, client_stream/4]).
-export([open/2, open/3, send/2, send_end/1, recv/1, recv/2, cancel/1]).
-export([before/1, after_response/1, wrap/1, metadata/1, set_metadata/2]).

-export_type([
    conn/0,
    call_opts/0,
    call_result/0,
    client_call/0,
    outcome/0,
    grpc_request/0,
    interceptor/0,
    interceptors/0,
    next/0
]).

-opaque conn() :: #{
    pid := pid(),
    scheme := binary(),
    authority := binary(),
    stack := interceptors()
}.

%% A request as it flows through the interceptor stack. The same uniform
%% shape livery's server middleware and livery_client layers use.
-type grpc_request() :: #{
    method := livery_grpc_service:method(),
    message := map() | tuple(),
    metadata := [{binary(), binary()}],
    opts := call_opts()
}.
-type next() :: fun((grpc_request()) -> call_result()).
-type interceptor() :: {module(), term()} | fun((grpc_request(), next()) -> call_result()).
-type interceptors() :: [interceptor()].

-type call_opts() :: #{
    %% Local receive bound; superseded by `deadline` when that is set.
    timeout => timeout(),
    %% Call deadline in milliseconds: sent as grpc-timeout and used to
    %% bound the wait.
    deadline => pos_integer(),
    metadata => [{binary(), binary()}],
    compression => livery_grpc_compression:algorithm(),
    %% Per-call interceptors, run inside the connection's stack.
    interceptors => interceptors()
}.

-type call_result() ::
    {ok, map() | tuple()}
    | {ok, [map() | tuple()]}
    | {error, {livery_grpc_status:status(), binary()}}
    | {error, {livery_grpc_status:status(), binary(), Details :: binary()}}
    | {error, term()}.

%% The gRPC status outcome of a call: success, or an error status with a
%% message and optional binary details (grpc-status-details-bin).
-type outcome() ::
    ok
    | {livery_grpc_status:status(), binary()}
    | {livery_grpc_status:status(), binary(), binary()}.

%% A live streaming call: drive it with send/2, send_end/1, and recv/1,2.
-opaque client_call() :: #{
    pid := pid(),
    stream_id := h2:stream_id(),
    proto := module(),
    input := atom(),
    output := atom(),
    request_compression := livery_grpc_compression:algorithm(),
    response_encoding := livery_grpc_compression:algorithm(),
    buffer := binary(),
    done := boolean(),
    outcome := outcome() | undefined
}.

-define(DEFAULT_TIMEOUT, 30000).
-define(MAX_RECV, 16 * 1024 * 1024).

%%====================================================================
%% Connection
%%====================================================================

-doc "Open an h2c connection to a gRPC server.".
-spec connect(string(), inet:port_number()) -> {ok, conn()} | {error, term()}.
connect(Host, Port) ->
    connect(Host, Port, #{}).

-doc """
Open a connection. `Opts`: `transport` (`tcp` for h2c, the default, or
`ssl`), `authority` (the `:authority` header, derived from host and port
if absent), `ssl_opts`, `timeout`, and `interceptors` (a layer stack run
around every unary and server-streaming call on this connection).
""".
-spec connect(string(), inet:port_number(), map()) -> {ok, conn()} | {error, term()}.
connect(Host, Port, Opts) ->
    Transport = maps:get(transport, Opts, tcp),
    case h2:connect(Host, Port, connect_opts(Transport, Opts)) of
        {ok, Pid} ->
            {ok, #{
                pid => Pid,
                scheme => scheme(Transport),
                authority => authority(Host, Port, Opts),
                stack => maps:get(interceptors, Opts, [])
            }};
        {error, _} = E ->
            E
    end.

-spec stack(conn()) -> interceptors().
stack(#{stack := Stack}) -> Stack.

-doc "Close a connection.".
-spec close(conn()) -> ok.
close(#{pid := Pid}) ->
    _ = h2:close(Pid),
    ok.

-doc "Look up a method descriptor by proto module, service, and RPC name.".
-spec method(module(), atom(), atom()) -> {ok, livery_grpc_service:method()} | error.
method(Proto, Service, Name) ->
    livery_grpc_service:method(Proto, Service, Name).

%%====================================================================
%% Calls
%%====================================================================

-doc "`call/4` with default options.".
-spec call(conn(), livery_grpc_service:method(), map() | tuple()) -> call_result().
call(Conn, Method, Request) ->
    call(Conn, Method, Request, #{}).

-doc """
Invoke a method. Unary returns `{ok, Reply}`; server-streaming returns
`{ok, [Reply]}`. A non-OK gRPC status is `{error, {Status, Message}}`.

The call runs through the connection's interceptor stack (plus any
per-call `interceptors`), the gRPC analogue of livery's server middleware
and `livery_client` layers: each interceptor is
`call(Request, Next, State)` and may rewrite the request, observe the
result, or short-circuit, with errors threaded as values.
""".
-spec call(conn(), livery_grpc_service:method(), map() | tuple(), call_opts()) -> call_result().
call(Conn, #{kind := Kind} = Method, Request, Opts) when
    Kind =:= unary; Kind =:= server_stream
->
    Stack = stack(Conn) ++ maps:get(interceptors, Opts, []),
    GReq = #{
        method => Method,
        message => Request,
        metadata => maps:get(metadata, Opts, []),
        opts => Opts
    },
    run_stack(Stack, fun(R) -> transport_call(Conn, R) end, GReq);
call(_Conn, #{kind := Kind}, _Request, _Opts) when
    Kind =:= client_stream; Kind =:= bidi
->
    {error, {use_open, <<"use client_stream/3,4 or open/3 for this kind">>}}.

%% The innermost handler: perform the unary/server-streaming call on the
%% wire and shape the result by kind. Interceptors may have rewritten the
%% request's metadata, so fold it back into the opts the transport uses.
-spec transport_call(conn(), grpc_request()) -> call_result().
transport_call(Conn, #{method := #{kind := Kind} = Method, message := Msg} = GReq) ->
    Opts = (maps:get(opts, GReq))#{metadata => maps:get(metadata, GReq)},
    case invoke(Conn, Method, Msg, Opts) of
        {ok, Replies, ok} when Kind =:= unary -> {ok, first(Replies)};
        {ok, Replies, ok} -> {ok, Replies};
        {ok, _Replies, Error} -> {error, Error};
        {error, _} = E -> E
    end.

%%====================================================================
%% Interceptor stack (the gRPC analogue of livery_client layers)
%%====================================================================

-spec run_stack(interceptors(), next(), grpc_request()) -> call_result().
run_stack([], Handler, Req) ->
    Handler(Req);
run_stack([Entry | Rest], Handler, Req) ->
    Next = fun(R) -> run_stack(Rest, Handler, R) end,
    call_entry(Entry, Req, Next).

-spec call_entry(interceptor(), grpc_request(), next()) -> call_result().
call_entry({Mod, State}, Req, Next) when is_atom(Mod) ->
    Mod:call(Req, Next, State);
call_entry(Fun, Req, Next) when is_function(Fun, 2) ->
    Fun(Req, Next).

-doc "Lift a request transformer into an interceptor.".
-spec before(fun((grpc_request()) -> grpc_request())) -> interceptor().
before(Fun) when is_function(Fun, 1) ->
    fun(Req, Next) -> Next(Fun(Req)) end.

-doc "Lift a result transformer (applied on success) into an interceptor.".
-spec after_response(fun((call_result()) -> call_result())) -> interceptor().
after_response(Fun) when is_function(Fun, 1) ->
    fun(Req, Next) ->
        case Next(Req) of
            {ok, _} = Ok -> Fun(Ok);
            Other -> Other
        end
    end.

-doc "Wrap a call to catch exceptions, mirroring `livery_client:wrap/1`.".
-spec wrap(fun((throw | error | exit, term(), list()) -> call_result())) -> interceptor().
wrap(Fun) when is_function(Fun, 3) ->
    fun(Req, Next) ->
        try
            Next(Req)
        catch
            Class:Reason:Stack -> Fun(Class, Reason, Stack)
        end
    end.

-doc "The request's call metadata (for use inside an interceptor).".
-spec metadata(grpc_request()) -> [{binary(), binary()}].
metadata(#{metadata := Md}) -> Md.

-doc "Add or replace call metadata on a request (for use in a `before`).".
-spec set_metadata([{binary(), binary()}], grpc_request()) -> grpc_request().
set_metadata(Md, Req) -> Req#{metadata => Md}.

%%====================================================================
%% Streaming calls (client-streaming and bidirectional)
%%====================================================================

-doc "`client_stream/4` with default options.".
-spec client_stream(conn(), livery_grpc_service:method(), [map() | tuple()]) -> call_result().
client_stream(Conn, Method, Requests) ->
    client_stream(Conn, Method, Requests, #{}).

-doc """
Client-streaming call: send all `Requests`, half-close, and return the
single reply (`{ok, Reply}`) or the error status.
""".
-spec client_stream(conn(), livery_grpc_service:method(), [map() | tuple()], call_opts()) ->
    call_result().
client_stream(Conn, Method, Requests, Opts) ->
    case open(Conn, Method, Opts) of
        {ok, Call} -> client_stream_run(Call, Requests);
        {error, _} = E -> E
    end.

-spec client_stream_run(client_call(), [map() | tuple()]) -> call_result().
client_stream_run(Call, Requests) ->
    case send_all(Call, Requests) of
        ok ->
            ok = send_end(Call),
            case drain(Call, []) of
                {ok, [Reply | _], ok} -> {ok, Reply};
                {ok, [], ok} -> {ok, #{}};
                {ok, _Replies, Error} -> {error, Error};
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

-spec send_all(client_call(), [map() | tuple()]) -> ok | {error, term()}.
send_all(_Call, []) ->
    ok;
send_all(Call, [Msg | Rest]) ->
    case send(Call, Msg) of
        ok -> send_all(Call, Rest);
        {error, _} = E -> E
    end.

%% Drain replies to end of stream, returning the replies and the outcome.
-spec drain(client_call(), [map() | tuple()]) ->
    {ok, [map() | tuple()], outcome()} | {error, term()}.
drain(Call, Acc) ->
    case recv(Call) of
        {ok, Msg, Call1} -> drain(Call1, [Msg | Acc]);
        {eof, Outcome, _Call1} -> {ok, lists:reverse(Acc), Outcome};
        {error, Reason, _Call1} -> {error, Reason}
    end.

-doc "`open/3` with default options.".
-spec open(conn(), livery_grpc_service:method()) -> {ok, client_call()} | {error, term()}.
open(Conn, Method) ->
    open(Conn, Method, #{}).

-doc """
Open a streaming call. Drive it with `send/2`, `send_end/1` (half-close),
and `recv/1,2`. Use this for bidirectional calls and for fine-grained
client-streaming. The connection's events go to the calling process, so
use the handle from there.
""".
-spec open(conn(), livery_grpc_service:method(), call_opts()) ->
    {ok, client_call()} | {error, term()}.
open(#{pid := Pid} = Conn, Method, Opts) ->
    Algorithm = maps:get(compression, Opts, identity),
    Headers = request_headers(Conn, Method, Algorithm, Opts),
    case h2:request(Pid, Headers, #{end_stream => false, handler => self()}) of
        {ok, StreamId} ->
            #{proto := Proto, input := Input, output := Output} = Method,
            {ok, #{
                pid => Pid,
                stream_id => StreamId,
                proto => Proto,
                input => Input,
                output => Output,
                request_compression => Algorithm,
                response_encoding => identity,
                buffer => <<>>,
                done => false,
                outcome => undefined
            }};
        {error, _} = E ->
            E
    end.

-doc "Send one request message on a streaming call.".
-spec send(client_call(), map() | tuple()) -> ok | {error, term()}.
send(#{pid := Pid, stream_id := StreamId, proto := Proto, input := Input} = Call, Msg) ->
    #{request_compression := Algorithm} = Call,
    case livery_grpc_wire:encode(Proto, Input, Msg, Algorithm) of
        {ok, Frame} -> h2:send_data(Pid, StreamId, iolist_to_binary(Frame), false);
        {error, _} = E -> E
    end.

-doc "Half-close the send side: no more requests will be sent.".
-spec send_end(client_call()) -> ok | {error, term()}.
send_end(#{pid := Pid, stream_id := StreamId}) ->
    h2:send_data(Pid, StreamId, <<>>, true).

-doc """
Cancel a streaming call, resetting its stream (the server sees a
disconnect). Use this to stop a stream early; unary calls are bounded by
their `deadline` instead.
""".
-spec cancel(client_call()) -> ok | {error, term()}.
cancel(#{pid := Pid, stream_id := StreamId}) ->
    h2:cancel(Pid, StreamId).

-doc "`recv/2` with the default timeout.".
-spec recv(client_call()) ->
    {ok, map() | tuple(), client_call()}
    | {eof, outcome(), client_call()}
    | {error, term(), client_call()}.
recv(Call) ->
    recv(Call, ?DEFAULT_TIMEOUT).

-doc """
Receive the next reply on a streaming call: `{ok, Reply, Call}`, `{eof,
Outcome, Call}` once the server has finished (carrying the gRPC status),
or `{error, Reason, Call}`.
""".
-spec recv(client_call(), timeout()) ->
    {ok, map() | tuple(), client_call()}
    | {eof, outcome(), client_call()}
    | {error, term(), client_call()}.
recv(#{buffer := Buffer} = Call, Timeout) ->
    case livery_grpc_frame:decode_one(Buffer, ?MAX_RECV) of
        {ok, Frame, Rest} -> decode_reply(Frame, Call#{buffer => Rest});
        {error, Reason} -> {error, Reason, Call};
        more -> recv_more(Call, Timeout)
    end.

-spec recv_more(client_call(), timeout()) ->
    {ok, map() | tuple(), client_call()}
    | {eof, outcome(), client_call()}
    | {error, term(), client_call()}.
recv_more(#{done := true} = Call, _Timeout) ->
    {eof, call_outcome(Call), Call};
recv_more(#{pid := Pid, stream_id := StreamId, buffer := Buffer} = Call, Timeout) ->
    receive
        {h2, Pid, {response, StreamId, _S, Headers}} ->
            Call1 = Call#{response_encoding => response_encoding(Headers)},
            case has_grpc_status(Headers) of
                true -> recv(Call1#{done => true, outcome => grpc_outcome(Headers)}, Timeout);
                false -> recv(Call1, Timeout)
            end;
        {h2, Pid, {data, StreamId, Data, _Fin}} ->
            recv(Call#{buffer => <<Buffer/binary, Data/binary>>}, Timeout);
        {h2, Pid, {trailers, StreamId, Trailers}} ->
            recv(Call#{done => true, outcome => grpc_outcome(Trailers)}, Timeout);
        {h2, Pid, {stream_reset, StreamId, Reason}} ->
            {error, {stream_reset, Reason}, Call}
    after Timeout ->
        {error, timeout, Call}
    end.

-spec decode_reply(livery_grpc_frame:frame(), client_call()) ->
    {ok, map() | tuple(), client_call()} | {error, term(), client_call()}.
decode_reply(Frame, #{proto := Proto, output := Output, response_encoding := Encoding} = Call) ->
    case livery_grpc_wire:decode_frame(Proto, Output, Encoding, Frame) of
        {ok, Msg} -> {ok, Msg, Call};
        {error, Reason} -> {error, Reason, Call}
    end.

-spec call_outcome(client_call()) -> outcome().
call_outcome(#{outcome := undefined}) -> {unknown, <<"missing grpc-status">>};
call_outcome(#{outcome := Outcome}) -> Outcome.

%% Send the request message and collect the response, returning the
%% decoded replies and the gRPC status outcome.
-spec invoke(conn(), livery_grpc_service:method(), map() | tuple(), call_opts()) ->
    {ok, [map() | tuple()], outcome()} | {error, term()}.
invoke(#{pid := Pid} = Conn, Method, Request, Opts) ->
    Algorithm = maps:get(compression, Opts, identity),
    #{proto := Proto, input := Input} = Method,
    case livery_grpc_wire:encode(Proto, Input, Request, Algorithm) of
        {ok, Frame} ->
            Headers = request_headers(Conn, Method, Algorithm, Opts),
            case h2:request(Pid, Headers, #{end_stream => false}) of
                {ok, StreamId} ->
                    ok = h2:send_data(Pid, StreamId, iolist_to_binary(Frame), true),
                    await(Pid, StreamId, Method, Opts);
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

%%====================================================================
%% Response collection
%%====================================================================

-spec await(pid(), h2:stream_id(), livery_grpc_service:method(), call_opts()) ->
    {ok, [map() | tuple()], outcome()} | {error, term()}.
await(Pid, StreamId, Method, Opts) ->
    Timeout = effective_timeout(Opts),
    State = #{status => undefined, data => [], encoding => identity},
    collect(Pid, StreamId, Method, Timeout, State).

%% A set deadline bounds the wait (plus slack for the status trailers to
%% arrive); otherwise the `timeout` option applies.
-spec effective_timeout(call_opts()) -> timeout().
effective_timeout(#{deadline := Ms}) when is_integer(Ms) ->
    Ms + 1000;
effective_timeout(Opts) ->
    maps:get(timeout, Opts, ?DEFAULT_TIMEOUT).

-spec collect(pid(), h2:stream_id(), livery_grpc_service:method(), timeout(), map()) ->
    {ok, [map() | tuple()], outcome()} | {error, term()}.
collect(Pid, StreamId, Method, Timeout, State) ->
    receive
        {h2, Pid, {response, StreamId, _S, Headers}} ->
            State1 = State#{encoding => response_encoding(Headers)},
            %% Trailers-Only: grpc-status arrives in the response headers.
            case has_grpc_status(Headers) of
                true -> finish(Method, State1, Headers);
                false -> collect(Pid, StreamId, Method, Timeout, State1)
            end;
        {h2, Pid, {data, StreamId, Data, _Fin}} ->
            #{data := Acc} = State,
            collect(Pid, StreamId, Method, Timeout, State#{data => [Data | Acc]});
        {h2, Pid, {trailers, StreamId, Trailers}} ->
            finish(Method, State, Trailers);
        {h2, Pid, {stream_reset, StreamId, Reason}} ->
            {error, {stream_reset, Reason}}
    after Timeout ->
        {error, timeout}
    end.

-spec finish(livery_grpc_service:method(), map(), [{binary(), binary()}]) ->
    {ok, [map() | tuple()], outcome()} | {error, term()}.
finish(#{proto := Proto, output := Output}, #{data := Acc, encoding := Encoding}, StatusHeaders) ->
    Bin = iolist_to_binary(lists:reverse(Acc)),
    case livery_grpc_wire:decode_all(Proto, Output, Encoding, Bin, ?MAX_RECV) of
        {ok, Replies} -> {ok, Replies, grpc_outcome(StatusHeaders)};
        {error, Reason} -> {error, {decode, Reason}}
    end.

%%====================================================================
%% Headers
%%====================================================================

-spec request_headers(
    conn(), livery_grpc_service:method(), livery_grpc_compression:algorithm(), call_opts()
) ->
    [{binary(), binary()}].
request_headers(#{scheme := Scheme, authority := Authority}, #{path := Path}, Algorithm, Opts) ->
    Base = [
        {<<":method">>, <<"POST">>},
        {<<":scheme">>, Scheme},
        {<<":authority">>, Authority},
        {<<":path">>, Path},
        {<<"te">>, <<"trailers">>},
        {<<"content-type">>, <<"application/grpc+proto">>},
        {<<"grpc-accept-encoding">>, livery_grpc_compression:accept_header()}
    ],
    WithEncoding = maybe_encoding(Algorithm, Base),
    WithTimeout = maybe_timeout(Opts, WithEncoding),
    WithTimeout ++ maps:get(metadata, Opts, []).

-spec maybe_timeout(call_opts(), [{binary(), binary()}]) -> [{binary(), binary()}].
maybe_timeout(#{deadline := Ms}, Headers) when is_integer(Ms) ->
    case livery_grpc_timeout:encode(Ms) of
        undefined -> Headers;
        Value -> Headers ++ [{<<"grpc-timeout">>, Value}]
    end;
maybe_timeout(_Opts, Headers) ->
    Headers.

-spec maybe_encoding(livery_grpc_compression:algorithm(), [{binary(), binary()}]) ->
    [{binary(), binary()}].
maybe_encoding(identity, Headers) ->
    Headers;
maybe_encoding(gzip, Headers) ->
    Headers ++ [{<<"grpc-encoding">>, <<"gzip">>}].

-spec response_encoding([{binary(), binary()}]) -> livery_grpc_compression:algorithm().
response_encoding(Headers) ->
    livery_grpc_compression:from_header(header(<<"grpc-encoding">>, Headers)).

-spec has_grpc_status([{binary(), binary()}]) -> boolean().
has_grpc_status(Headers) ->
    header(<<"grpc-status">>, Headers) =/= undefined.

-spec grpc_outcome([{binary(), binary()}]) ->
    ok
    | {livery_grpc_status:status(), binary()}
    | {livery_grpc_status:status(), binary(), binary()}.
grpc_outcome(Headers) ->
    case header(<<"grpc-status">>, Headers) of
        undefined ->
            {unknown, <<"missing grpc-status">>};
        Code ->
            case livery_grpc_status:from_binary(Code) of
                ok -> ok;
                Status -> error_outcome(Status, Headers)
            end
    end.

-spec error_outcome(livery_grpc_status:status(), [{binary(), binary()}]) ->
    {livery_grpc_status:status(), binary()} | {livery_grpc_status:status(), binary(), binary()}.
error_outcome(Status, Headers) ->
    Msg = message(Headers),
    case header(<<"grpc-status-details-bin">>, Headers) of
        undefined -> {Status, Msg};
        Encoded -> {Status, Msg, base64:decode(Encoded)}
    end.

-spec message([{binary(), binary()}]) -> binary().
message(Headers) ->
    case header(<<"grpc-message">>, Headers) of
        undefined -> <<>>;
        Encoded -> livery_grpc_status:decode_message(Encoded)
    end.

%%====================================================================
%% Helpers
%%====================================================================

-spec connect_opts(tcp | ssl, map()) -> map().
connect_opts(Transport, Opts) ->
    Base = #{transport => Transport},
    case maps:find(ssl_opts, Opts) of
        {ok, SslOpts} -> Base#{ssl_opts => SslOpts};
        error -> Base
    end.

-spec scheme(tcp | ssl) -> binary().
scheme(ssl) -> <<"https">>;
scheme(tcp) -> <<"http">>.

-spec authority(string(), inet:port_number(), map()) -> binary().
authority(Host, Port, Opts) ->
    case maps:find(authority, Opts) of
        {ok, A} -> A;
        error -> iolist_to_binary([Host, ":", integer_to_binary(Port)])
    end.

-spec header(binary(), [{binary(), binary()}]) -> binary() | undefined.
header(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, V} -> V;
        false -> undefined
    end.

-spec first([map() | tuple()]) -> map() | tuple().
first([Reply | _]) -> Reply;
first([]) -> #{}.
