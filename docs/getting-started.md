# Getting started

This guide builds and runs a small gRPC service in a few minutes. You will
define a service, implement it, start a server, call it from Erlang, and
hit it with grpcurl.

## Prerequisites

- Erlang/OTP 26+ and rebar3.
- livery_grpc as a dependency (see the
  [Erlang integration guide](guides/erlang-integration.md) for a new
  project). The snippets below use the `helloworld` fixture shipped with
  livery_grpc.

## 1. Define the service

Put a `.proto` file in `proto/`:

```proto
syntax = "proto3";
package helloworld;

service Greeter {
  rpc SayHello (HelloRequest) returns (HelloReply);
}

message HelloRequest { string name = 1; }
message HelloReply   { string message = 1; }
```

`rebar3 compile` runs `rebar3_gpb_plugin`, which compiles this to the
`helloworld_pb` module. Messages are maps.

## 2. Implement the handler

A handler is a module with one function per RPC, named in snake_case. A
unary function takes the request and a context and returns `{ok, Reply}`:

```erlang
-module(my_greeter).
-export([say_hello/2]).

say_hello(#{name := Name}, _Ctx) ->
    {ok, #{message => <<"hello ", Name/binary>>}}.
```

## 3. Start a server

A gRPC server is its own listener:

```erlang
{ok, Server} = livery_grpc:start_server(#{
    port     => 50051,
    services => [
        #{proto => helloworld_pb, service => 'Greeter', handler => my_greeter}
    ]
}).
```

## 4. Call it from Erlang

```erlang
{ok, Conn} = livery_grpc_client:connect("localhost", 50051),
{ok, M}    = livery_grpc_client:method(helloworld_pb, 'Greeter', 'SayHello'),
{ok, Reply} = livery_grpc_client:call(Conn, M, #{name => <<"ada">>}),
%% Reply = #{message => <<"hello ada">>}
ok = livery_grpc_client:close(Conn).
```

## 5. Call it with grpcurl

Start the server with reflection on and tools work without a local
`.proto`:

```erlang
livery_grpc:start_server(#{port => 50051, reflection => true,
                           services => [...]}).
```

```
$ grpcurl -plaintext localhost:50051 list
$ grpcurl -plaintext -d '{"name":"ada"}' \
    localhost:50051 helloworld.Greeter/SayHello
{
  "message": "hello ada"
}
```

## Next steps

- The [basics tutorial](basics-tutorial.md) builds RouteGuide, a service
  that uses all four call types.
- The guides cover deadlines, metadata, interceptors, streaming, and more.
- To add livery_grpc to your own project, see the
  [Erlang integration guide](guides/erlang-integration.md).
