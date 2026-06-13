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
proto/                     .proto fixtures (helloworld), compiled to
                           src/*_pb.erl by rebar3_gpb_plugin (gpb, maps
                           mode); generated *_pb modules are excluded from
                           erlfmt, elvis, and xref
src/livery_grpc.erl         Public facade: dedicated gRPC listener
                            (start_server) with reflection/compression opts
src/livery_grpc_server.erl  Dispatch POST /pkg.Svc/Method to callbacks; all
                            four call kinds; grpc and gRPC-Web framing
src/livery_grpc_client.erl  Call services over the h2 client (erpc-like);
                            interceptor stack; streaming handle
src/livery_grpc_stream.erl  Server-side stream handle (recv/recv_all/send)
                            for client-streaming and bidirectional handlers
src/livery_grpc_service.erl Method descriptors from gpb introspection
src/livery_grpc_codegen.erl Generate <svc>_client stubs + <svc>_service
                            behaviour (make stubs)
src/livery_grpc_wire.erl    Message <-> wire glue (codec+compression+frame)
src/livery_grpc_frame.erl   Length-prefixed framing + streaming decoder
src/livery_grpc_codec.erl   encode/decode glue over the gpb module
src/livery_grpc_compression Per-message identity/gzip
src/livery_grpc_status.erl  Canonical codes <-> grpc-status/grpc-message
src/livery_grpc_timeout.erl grpc-timeout deadlines
src/livery_grpc_web.erl     gRPC-Web framing (binary + text)
src/livery_grpc_reflection  grpc.reflection.v1 service (bidi)
src/livery_grpc_health.erl  grpc.health.v1 service (Check + Watch)
src/livery_grpc_health_store gen_server: status + watch subscriptions
src/livery_grpc_listener.erl gen_server owning one h2 listener (so it
                            outlives the caller); supervised by
src/livery_grpc_server_sup  dynamic supervisor of running servers
src/livery_grpc_app.erl / _sup.erl   application + supervisor (health store,
                            server supervisor)
```

## Required checks

Every change must be formatted and pass all checks before committing:

```bash
rebar3 fmt          # auto-format (always run first)
rebar3 compile      # must compile cleanly (warnings_as_errors)
rebar3 lint         # elvis
rebar3 xref         # cross-reference analysis
rebar3 dialyzer     # type checking
rebar3 eunit        # unit + property tests
rebar3 ct           # Common Test: livery_grpc_e2e_SUITE (real server)
```

`make interop` runs grpcurl against a real server out of band; the same
checks also run inside `livery_grpc_e2e_SUITE`'s grpcurl group.

`make check` runs the offline gate (compile, xref, dialyzer, lint, fmt,
eunit). `warn_missing_spec` is deliberately not enabled: gpb-generated
modules cannot satisfy it. Hand-written modules carry specs; dialyzer
enforces types.

`livery` is consumed from `_checkouts/livery` (a symlink to the sibling
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
