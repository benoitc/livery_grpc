# Changelog

All notable changes to this project are documented here. The format is
based on Keep a Changelog, and this project adheres to Semantic
Versioning.

## [Unreleased]

### Added
- Project scaffold: OTP application, supervisor, build pipeline with
  `gpb` and `rebar3_gpb_plugin`, sample `helloworld.proto`.
- Wire layer: `livery_grpc_frame` (length-prefixed framing + streaming
  decoder), `livery_grpc_status` (canonical codes, grpc-message
  encoding, trailers), `livery_grpc_compression` (identity + gzip),
  `livery_grpc_codec` (gpb glue + content-type checks). Property and unit
  tests.
- `livery_grpc_service`: method descriptors derived from gpb
  introspection (wire path, message types, call kind, snake_case callback
  name) and a path-keyed routing index.
- Server: `livery_grpc:start_server/1` runs gRPC on a dedicated h2
  listener; `livery_grpc_server` dispatches `POST /pkg.Svc/Method` to the
  bound callback module. Unary and server-streaming, with status in
  trailers (and Trailers-Only for pre-dispatch errors). End-to-end tests
  over h2c cover success, error status, handler crash, unknown method,
  and streaming.
- Client: `livery_grpc_client` calls gRPC services over the h2 client
  (unary and server-streaming), with metadata and gzip. `livery_grpc_wire`
  centralises message encode/decode for both sides. In-tree client tests
  cover unary, error status, server-streaming, and gzip both directions.
- Cross-cutting: `grpc-timeout` deadlines (client sends and bounds the
  wait; server parses, exposes in the context, and aborts a unary handler
  that overruns), error details via `grpc-status-details-bin`, request
  metadata, and livery middleware as gRPC interceptors.
- Health: the standard `grpc.health.v1.Health` service
  (`livery_grpc_health:service/0`), with per-service serving status.
  `Check` is unary; `Watch` emits the current status once (live updates
  follow the bidirectional work).
- gRPC-Web: `livery_grpc_web` framing on the same server (binary and
  text), with the status delivered as an in-body trailer frame. Unary and
  server-streaming. Reflection is deferred: its RPC is bidirectional and
  waits on the h2 bidi work.
- Example (`greeter_example`), a quickstart guide, and a `grpcurl` interop
  smoke test (`make interop`) confirming on-the-wire compliance with an
  external gRPC client.
- Client-streaming and bidirectional streaming on both sides, on h2
  0.10.0. The server reads requests through a `livery_grpc_stream` handle
  and interleaves replies in the chunked producer; the client adds
  `client_stream/3,4` and `open/2,3` + `send/2` + `send_end/1` +
  `recv/1,2`. All four call types are verified against grpcurl.
- Client interceptor stack, the outbound twin of livery's server
  middleware: `interceptors` on `connect/3` or per call, with `before/1`,
  `after_response/1`, and `wrap/1`, matching the `livery_client` layer
  shape (Tower layers on the BEAM).
