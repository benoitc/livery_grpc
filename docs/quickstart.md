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

## What works today

Unary and server-streaming, on the server and the client, plus health and
gRPC-Web. Client-streaming, bidirectional streaming, and server reflection
are bidirectional and land with the underlying HTTP/2 bidi support.
