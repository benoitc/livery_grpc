# Design: gRPC on Erlang and livery

This page explains how livery_grpc maps gRPC onto Erlang/OTP and
[livery](https://github.com/benoitc/livery), and why it is built the way
it is. Read it if you want to understand the runtime, extend livery_grpc,
or judge whether it fits your system.

## gRPC is HTTP/2

A gRPC call is an HTTP/2 stream: request HEADERS, then DATA frames each
carrying a length-prefixed protobuf message, then a final HEADERS frame
(the trailers) carrying `grpc-status`. Streaming is just more DATA frames;
bidirectional is DATA flowing both ways on the one stream.

livery already implements HTTP/2, on both sides, with trailers and
streaming, through its `h2` dependency. So livery_grpc does not implement a
transport. It implements the gRPC framing and dispatch on top of livery's
`h2` server and client. This is the whole reason the project is small.

## The request-worker model

livery serves each request in its own worker process. The adapter
(`livery_h2`) turns inbound HTTP/2 events into a request value and a body
reader, runs the handler, and writes the response by walking a body
variant: a full body, or a `{chunked, Producer}` body where `Producer` is
called with a `Send` function and emits frames until it returns, followed
by trailers.

gRPC fits this directly:

- A **unary** reply is a single framed message followed by status
  trailers.
- A **server-streaming** reply is a `{chunked, Producer}` body: the
  producer runs the handler's `Send` callback, framing each message, then
  the trailers carry the final status.

The same worker that runs the producer also owns the request body reader.
That is the key point for streaming: request DATA arrives at the worker
(through livery's body reader) and response DATA leaves the worker (through
the producer's `Send`). So **client-streaming and bidirectional need no
stream takeover**. The handler reads requests and writes replies,
interleaved, in the one worker process, inside the chunked producer.
`livery_grpc_stream` wraps the body reader as a sequence of decoded
messages (`recv/1`, `recv_all/1`) and, for bidirectional, adds `send/2`.

## Mapping gRPC to Erlang

- A **service** is a callback module. Each RPC is one function named in
  snake_case (`SayHello` becomes `say_hello`). The function shape follows
  the call type (see [core concepts](core-concepts.md)).
- The **context** is a map passed to every callback: metadata, the method
  descriptor, the deadline, and the underlying request.
- A **status** is the function's result. `{ok, Reply}` is success;
  `{error, Status}`, `{error, {Status, Msg}}`, or
  `{error, {Status, Msg, Details}}` is a gRPC error. A crash becomes
  `internal`.
- **Interceptors** are Tower-style layers. On the server they are livery
  middleware (the `middleware` option); on the client they are a layer
  stack with the same `call(Request, Next, State)` shape as
  `livery_client`. Calling a service reads like `erpc`.

This is the design goal: you write Erlang, and gRPC is the transport.

## Descriptors from gpb, at runtime

`rebar3_gpb_plugin` compiles each `.proto` to a module with gpb in maps
mode, so messages are plain maps. That module also carries introspection:
service names, per-method input/output types, and streaming flags.
`livery_grpc_service` reads that at runtime to build method descriptors,
so there is no second generated dispatch layer to keep in sync with the
messages. The optional generated client stubs and service behaviours
(`livery_grpc_codegen`) are sugar on top, not required.

Reflection serves `FileDescriptorProto` bytes that gpb emits with its
`descriptor` option, so tools can discover services with no local `.proto`.

## OTP shape

The `livery_grpc` application supervises:

- `livery_grpc_health_store`, the gen_server holding health status and
  Watch subscriptions.
- `livery_grpc_server_sup`, a dynamic supervisor of running servers.

`livery_grpc:start_server/1` adds a `livery_grpc_listener` child under that
supervisor. The listener owns the h2 listen socket, which matters: a
listen socket belongs to the process that opens it, so it must be a
long-lived one. Because the listener is supervised, a server started from
a short-lived process (a test setup, a one-off call) keeps running. The
client connection, by contrast, is owned by whoever calls `connect/2,3`,
and its events are delivered there, so you make calls from that process.

## Notable decisions

- **A gRPC server is its own listener**, not a route mounted on a shared
  livery service. gRPC has its own content types, routing
  (`/package.Service/Method`), and trailer semantics, and the dispatcher
  owns every stream, which keeps streaming clean.
- **Trailers-Only for fast errors.** A request that fails before dispatch
  (wrong content type, unknown method) replies with a single HEADERS block
  carrying the status. livery's `emit/3` drops trailers on an empty body,
  so the status is placed in the response headers instead; a normal
  response uses real trailers.
- **gRPC-Web** is a second framing path: the status rides in an in-body
  trailer frame instead of HTTP trailers, and the text variant base64s the
  body, so it works through browsers and HTTP/1.1.

## Bidirectional and h2

Bidirectional streaming needs the h2 layer to route a stream's events to a
per-call process, apply receive and send backpressure, and cancel a single
stream. These shipped in h2 0.10.0, which livery_grpc requires. With them,
the worker model above carries all four call types without special cases.

## See also

- The [Erlang integration guide](guides/erlang-integration.md) is the
  practical companion: how to wire livery_grpc into your own application.
- [livery](https://github.com/benoitc/livery), the framework this builds
  on.
