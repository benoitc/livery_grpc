# Agents

Instructions for AI coding agents working on this project.

## Project Overview

`livery_grpc` adds gRPC to Erlang on the `livery` HTTP/2 stack (the
sibling `livery` project), for both serving and calling services.
Developers write plain Erlang; the gRPC wire format is generated from
`.proto` files and handled by the runtime. It is a companion application
that depends on `livery`.

gRPC is HTTP/2 + length-prefixed protobuf frames + status in trailers.
`livery`'s `h2` dependency provides a client and server with trailers and
streaming, so both sides of gRPC run on it natively. Hackney is not used
(it cannot send request trailers or do bidi).

```
proto/                     .proto sources, compiled to src/*_pb.erl by
                           rebar3_gpb_plugin (gpb, maps mode) at build time
src/livery_grpc.erl        Public facade: dedicated gRPC listener
                           (start_link/start_server) + server/client entry
src/livery_grpc_frame.erl  Length-prefixed framing + streaming decoder
src/livery_grpc_codec.erl  encode/decode glue over the gpb module
src/livery_grpc_status.erl Canonical codes <-> grpc-status/grpc-message
src/livery_grpc_server.erl Dispatch POST /pkg.Svc/Method to callbacks
src/livery_grpc_client.erl Call services over the h2 client (erpc-like)
src/livery_grpc_app.erl / _sup.erl   application + supervisor
```

## Build and checks

- `make compile` builds (runs the proto step first).
- `make check` is the offline gate: compile, xref, dialyzer, lint, fmt,
  eunit.
- `livery` is consumed from `_checkouts/livery` (a symlink to the sibling
  checkout) until it is published to hex.

## Conventions

- Generated `src/*_pb.erl` modules are not hand-edited and are excluded
  from erlfmt and the style rules.
- Match the house style of the other livery companions (livery_s3,
  livery_stripe): Apache-2.0, ex_doc, erlfmt, rebar3_lint.

## Key gotcha

`livery:emit/3` drops trailers when the response body is `empty`
(`livery/src/livery.erl:220`). For a gRPC Trailers-Only error, carry
`grpc-status` in the response headers with an empty body; for a normal
response with no message but real trailers, use a `{full, <<>>}` body so
the trailing HEADERS block is emitted.
