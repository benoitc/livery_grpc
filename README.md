# livery_grpc

gRPC for Erlang, built on the [livery](https://github.com/benoitc/livery)
HTTP/2 stack. Server side and client side. You write plain Erlang; the
gRPC wire format is generated from your `.proto` files and handled for you.

See `docs/getting-started.md` to build and call a service, the
[basics tutorial](docs/basics-tutorial.md) for a full RouteGuide example,
and `doc/features.md` for the plan. livery_grpc is a companion to
[livery](https://github.com/benoitc/livery).

Working today: all four call types (unary, server-streaming,
client-streaming, bidirectional) on both the server and client, deadlines,
error details, gzip, livery middleware as interceptors, the standard
health service, gRPC-Web (binary and text), and server reflection
(`reflection => true`, so grpcurl/Postman discover the API with no local
`.proto`).

## Why

gRPC is HTTP/2 plus length-prefixed protobuf frames plus status in
trailers. livery already ships an HTTP/2 client and server with trailers
and streaming, so gRPC runs natively on it, both directions, without an
extra transport.

- Server and client on livery's own `h2` engine.
- Messages compiled from `.proto` to Erlang modules at build time (gpb).
- All four call types: unary, server-streaming, client-streaming,
  bidirectional.
- Calling a remote service reads like `erpc`; exposing one is a behaviour
  you implement in Erlang. Optional generated stubs (`make stubs`) give a
  typed call per RPC and a compiler-checked service behaviour.

## Layout

- `proto/` your `.proto` files (compiled to `src/*_pb.erl` by
  `rebar3_gpb_plugin`).
- `src/` the gRPC runtime (framing, codec, status, server, client).
- `examples/` a sample service over the canonical `helloworld.proto`.

## Build

```
make compile
make check
```

`livery` is consumed from `_checkouts/livery` until it is published to
hex.

## License

Apache-2.0.
