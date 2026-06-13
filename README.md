# livery_grpc

gRPC for Erlang, built on the [livery](https://github.com/benoitc/livery)
HTTP/2 stack. Server side and client side. You write plain Erlang; the
gRPC wire format is generated from your `.proto` files and handled for you.

See `docs/quickstart.md` to build and call a service, and
`doc/features.md` for the plan.

Working today: all four call types (unary, server-streaming,
client-streaming, bidirectional) on both the server and client, deadlines,
error details, gzip, livery middleware as interceptors, the standard
health service, and gRPC-Web (binary and text). Server reflection is
deferred (its own RPC is bidirectional; the plumbing is in place to add
it next).

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
  you implement in Erlang.

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
