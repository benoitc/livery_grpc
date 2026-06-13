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
