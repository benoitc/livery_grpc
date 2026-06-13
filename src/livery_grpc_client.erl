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

This release covers unary and server-streaming. A server-streaming call
collects all replies; `call/4` returns `{ok, [Reply]}` for that kind.
Client-streaming and bidirectional arrive with the h2 bidi support they
need.
""".

-export([connect/2, connect/3, close/1]).
-export([method/3]).
-export([call/3, call/4]).

-export_type([conn/0, call_opts/0, call_result/0]).

-opaque conn() :: #{pid := pid(), scheme := binary(), authority := binary()}.

-type call_opts() :: #{
    timeout => timeout(),
    metadata => [{binary(), binary()}],
    compression => livery_grpc_compression:algorithm()
}.

-type call_result() ::
    {ok, map() | tuple()}
    | {ok, [map() | tuple()]}
    | {error, {livery_grpc_status:status(), binary()}}
    | {error, term()}.

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
if absent), `ssl_opts`, `timeout`.
""".
-spec connect(string(), inet:port_number(), map()) -> {ok, conn()} | {error, term()}.
connect(Host, Port, Opts) ->
    Transport = maps:get(transport, Opts, tcp),
    case h2:connect(Host, Port, connect_opts(Transport, Opts)) of
        {ok, Pid} ->
            {ok, #{
                pid => Pid,
                scheme => scheme(Transport),
                authority => authority(Host, Port, Opts)
            }};
        {error, _} = E ->
            E
    end.

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
""".
-spec call(conn(), livery_grpc_service:method(), map() | tuple(), call_opts()) -> call_result().
call(Conn, #{kind := unary} = Method, Request, Opts) ->
    case invoke(Conn, Method, Request, Opts) of
        {ok, Replies, ok} -> {ok, first(Replies)};
        {ok, _Replies, {Status, Msg}} -> {error, {Status, Msg}};
        {error, _} = E -> E
    end;
call(Conn, #{kind := server_stream} = Method, Request, Opts) ->
    case invoke(Conn, Method, Request, Opts) of
        {ok, Replies, ok} -> {ok, Replies};
        {ok, _Replies, {Status, Msg}} -> {error, {Status, Msg}};
        {error, _} = E -> E
    end;
call(_Conn, #{kind := Kind}, _Request, _Opts) when
    Kind =:= client_stream; Kind =:= bidi
->
    {error, {unimplemented, <<"streaming kind not yet supported">>}}.

%% Send the request message and collect the response, returning the
%% decoded replies and the gRPC status outcome.
-spec invoke(conn(), livery_grpc_service:method(), map() | tuple(), call_opts()) ->
    {ok, [map() | tuple()], ok | {livery_grpc_status:status(), binary()}} | {error, term()}.
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
    {ok, [map() | tuple()], ok | {livery_grpc_status:status(), binary()}} | {error, term()}.
await(Pid, StreamId, Method, Opts) ->
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
    State = #{status => undefined, data => [], encoding => identity},
    collect(Pid, StreamId, Method, Timeout, State).

-spec collect(pid(), h2:stream_id(), livery_grpc_service:method(), timeout(), map()) ->
    {ok, [map() | tuple()], ok | {livery_grpc_status:status(), binary()}} | {error, term()}.
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
    {ok, [map() | tuple()], ok | {livery_grpc_status:status(), binary()}} | {error, term()}.
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
    WithEncoding ++ maps:get(metadata, Opts, []).

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

-spec grpc_outcome([{binary(), binary()}]) -> ok | {livery_grpc_status:status(), binary()}.
grpc_outcome(Headers) ->
    case header(<<"grpc-status">>, Headers) of
        undefined ->
            {unknown, <<"missing grpc-status">>};
        Code ->
            case livery_grpc_status:from_binary(Code) of
                ok -> ok;
                Status -> {Status, message(Headers)}
            end
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
