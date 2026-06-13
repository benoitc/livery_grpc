# Introduction to livery_grpc

livery_grpc adds gRPC to Erlang. You define services in `.proto` files,
implement them as ordinary Erlang modules, and call them with an API that
reads like `erpc`. It runs on the HTTP/2 stack of
[livery](https://github.com/benoitc/livery), the Erlang web framework it
ships alongside, so the server and the client both speak real gRPC over
HTTP/2.

If you have used gRPC in Go, Java, or Python, everything here will feel
familiar. The only difference is that the code is Erlang.

## Why gRPC

gRPC lets a client call a method on a server on another machine as if it
were local. You define services and messages once, in Protocol Buffers,
and both sides share that contract. Calls are binary, multiplexed over
HTTP/2, and support four shapes: unary, server-streaming,
client-streaming, and bidirectional.

## Why livery_grpc

gRPC is HTTP/2 plus length-prefixed protobuf messages plus a status in the
trailers. livery already provides an HTTP/2 server and client with
trailers and streaming, so gRPC runs on it natively, in both directions,
with no extra transport.

- Server and client on livery's own `h2` engine.
- Messages compiled from `.proto` to Erlang modules at build time, with
  [gpb](https://github.com/tomas-abrahamsson/gpb).
- All four call types.
- Handlers are plain Erlang functions; the wire format is handled for you.
- The standard health and reflection services, gRPC-Web, gzip, deadlines,
  metadata, and composable interceptors.

## Where to go next

- [Core concepts](core-concepts.md) explains services, the four call
  types, metadata, deadlines, and status.
- [Getting started](getting-started.md) builds and runs a service in a few
  minutes.
- [Basics tutorial](basics-tutorial.md) walks through a complete service,
  RouteGuide, that uses all four call types.
- The guides cover one task each (authentication, deadlines, interceptors,
  and so on).
- [Design](design.md) explains how livery_grpc maps gRPC onto Erlang and
  livery, and why.

## Not covered

livery_grpc focuses on the gRPC protocol on the BEAM. Some topics in the
[gRPC guides](https://grpc.io/docs/guides/) are out of scope, mostly
client-side load balancing and observability that the direct livery_grpc
client does not implement: benchmarking, custom backend metrics, custom
load balancing, custom name resolution, debugging (grpcdebug), keepalive,
OpenTelemetry metrics, performance best practices, request hedging, and
service config.
