# Quickstart

This guide builds a Greeter service and calls it, then hits it with
`grpcurl`.

## 1. Define a service

Put your `.proto` under `proto/`. The build compiles it to an Erlang
module (`*_pb`) with `gpb`.

```proto
// proto/helloworld.proto
syntax = "proto3";
package helloworld;

service Greeter {
  rpc SayHello (HelloRequest) returns (HelloReply);
  rpc SayHelloStream (HelloRequest) returns (stream HelloReply);
}

message HelloRequest { string name = 1; }
message HelloReply   { string message = 1; }
```

## 2. Implement the handler

One Erlang function per RPC, named in snake_case. A unary RPC takes the
request and a context and returns `{ok, Reply}` or an error status. A
server-streaming RPC also gets a `Send` function to push replies.

```erlang
-module(my_greeter).
-export([say_hello/2, say_hello_stream/3]).

say_hello(#{name := Name}, _Ctx) ->
    {ok, #{message => <<"hello ", Name/binary>>}}.

say_hello_stream(#{name := Name}, Send, _Ctx) ->
    Send(#{message => <<"hi ", Name/binary>>}),
    ok.
```

Return an error with `{error, Status}` (a status atom such as
`not_found`), `{error, {Status, Message}}`, or
`{error, {Status, Message, DetailsBin}}` to attach
`grpc-status-details-bin`.

## 3. Start a server

A gRPC server is its own listener.

```erlang
{ok, Server} = livery_grpc:start_server(#{
    port     => 50051,
    services => [
        #{proto => helloworld_pb, service => 'Greeter', handler => my_greeter}
    ]
}).
```

Pass `transport => ssl` with `cert` and `key` for TLS, `compression =>
gzip` to compress replies, and `middleware => Stack` to run livery
middleware as interceptors. Add `livery_grpc_health:service()` to the
list for the standard health service.

## 4. Call it

```erlang
{ok, Conn} = livery_grpc_client:connect("localhost", 50051),
{ok, M}    = livery_grpc_client:method(helloworld_pb, 'Greeter', 'SayHello'),
{ok, Reply} = livery_grpc_client:call(Conn, M, #{name => <<"ada">>}),
%% Reply = #{message => <<"hello ada">>}
ok = livery_grpc_client:close(Conn).
```

Per-call options: `deadline` (ms, sent as `grpc-timeout`), `metadata`
(extra headers), `compression`.

### Interceptors (Tower-style layers)

Both sides are composable in the livery (Axum + Tower) spirit. On the
server, `middleware => Stack` runs livery middleware around every call. On
the client, `interceptors` compose layers around unary and
server-streaming calls, the same `call(Request, Next, State)` shape as
`livery_client`:

```erlang
Trace = livery_grpc_client:before(fun(Req) ->
    livery_grpc_client:set_metadata([{<<"x-trace-id">>, new_id()}], Req)
end),
{ok, Conn} = livery_grpc_client:connect("localhost", 50051,
                                        #{interceptors => [Trace]}).
```

## 5. Talk to it with grpcurl

```
$ grpcurl -plaintext -proto proto/helloworld.proto \
    -d '{"name":"ada"}' localhost:50051 helloworld.Greeter/SayHello
{
  "message": "hello ada"
}
```

`make interop` runs this smoke test for you (skipped if `grpcurl` is not
installed).

## Streaming

Client-streaming and bidirectional callbacks take a stream handle instead
of a single request:

```erlang
%% client-streaming: read all requests, reply once
say_hello_collect(Stream, _Ctx) ->
    {ok, Requests, _} = livery_grpc_stream:recv_all(Stream),
    {ok, #{message => <<"got ", (integer_to_binary(length(Requests)))/binary>>}}.

%% bidirectional: echo each request as it arrives
say_hello_chat(Stream, _Ctx) ->
    case livery_grpc_stream:recv(Stream) of
        {ok, #{name := N}, S1} ->
            livery_grpc_stream:send(S1, #{message => <<"hi ", N/binary>>}),
            say_hello_chat(S1, undefined);
        {eof, _} -> ok
    end.
```

On the client, use `client_stream/3` for client-streaming, and `open/2` +
`send/2` + `send_end/1` + `recv/1` for bidirectional.

## Reflection

Start the server with `reflection => true` to mount
`grpc.reflection.v1.ServerReflection`. Tools then work without a local
`.proto`:

```
$ grpcurl -plaintext localhost:50051 list
$ grpcurl -plaintext -d '{"name":"ada"}' localhost:50051 helloworld.Greeter/SayHello
```

## What works today

All four call types on the server and the client, plus health, gRPC-Web,
and server reflection.
