# Core concepts

This page covers the concepts you need to work with livery_grpc: the
service definition, the four call types, and how they map to Erlang.

## Service definition

You start with a `.proto` file. It declares a service, its methods, and
the messages they exchange.

```proto
syntax = "proto3";
package helloworld;

service Greeter {
  rpc SayHello (HelloRequest) returns (HelloReply);
}

message HelloRequest { string name = 1; }
message HelloReply   { string message = 1; }
```

At build time, `rebar3_gpb_plugin` compiles this to an Erlang module
(`helloworld_pb`) using gpb in maps mode. Messages are plain maps:
`#{name => <<"ada">>}`. livery_grpc reads the service's methods, message
types, and call kinds from that module at runtime, so there is no separate
generated dispatch layer to keep in sync.

## The four call types

gRPC has four call types. livery_grpc supports all of them.

- **Unary**: one request, one reply. The most common shape.
- **Server-streaming**: one request, a stream of replies.
- **Client-streaming**: a stream of requests, one reply.
- **Bidirectional**: both sides stream, independently.

On the server, each method is one Erlang function whose name is the RPC
name in snake_case. The shape of the function follows the call type:

```erlang
%% unary: request and context in, reply out
say_hello(#{name := Name}, _Ctx) ->
    {ok, #{message => <<"hello ", Name/binary>>}}.

%% server-streaming: a Send function pushes replies
say_hello_stream(#{name := Name}, Send, _Ctx) ->
    Send(#{message => <<"hi ", Name/binary>>}),
    ok.

%% client-streaming and bidirectional: a stream handle to recv (and send)
say_hello_collect(Stream, _Ctx) ->
    {ok, Requests, _} = livery_grpc_stream:recv_all(Stream),
    {ok, #{message => summarize(Requests)}}.
```

See the [streaming guide](guides/streaming.md) for each shape in full.

## The context

Every callback receives a context map, `Ctx`. It carries the call
metadata, the method descriptor, the deadline, and the underlying request:

```erlang
#{metadata := [{binary(), binary()}],
  method   := map(),
  deadline := timeout(),
  req      := livery_req:req()}
```

## Metadata

Metadata is key-value pairs sent alongside a call, as HTTP/2 headers. A
client attaches it per call; a handler reads it from `Ctx`. Use it for
auth tokens, request ids, and tracing. See the
[metadata guide](guides/metadata.md).

## Deadlines

A client sets a deadline; it travels on the wire as `grpc-timeout`. The
server exposes it in `Ctx` and aborts a unary handler that overruns. See
the [deadlines guide](guides/deadlines.md).

## Status

Every call ends with a status. Success is `ok`; an error is a status code
(such as `not_found` or `invalid_argument`) with an optional message and
details. A handler returns `{error, Status}` or `{error, {Status, Msg}}`;
a client sees `{error, {Status, Msg}}`. See the
[error handling](guides/error-handling.md) and
[status codes](guides/status-codes.md) guides.

## Connections

A client opens a connection with `livery_grpc_client:connect/2,3` and
makes many calls on it. A server is a dedicated listener started with
`livery_grpc:start_server/1`. Both speak gRPC over HTTP/2.
