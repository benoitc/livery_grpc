# livery_grpc - implementation plan

## Status

All phases below are implemented and tested (unit + property + in-tree
interop, plus external grpcurl compliance via `make interop`): the wire
layer, descriptors and codegen, the server and client for all four call
types, deadlines, error details, gzip, interceptors on both sides, the
health and reflection services, and gRPC-Web. The plan text below is kept
as the original design record; the "GATED" notes referred to h2's
bidirectional support, which shipped in h2 0.10.0 and is now in use.

## Context

`livery` is an Erlang web framework over HTTP/1.1, HTTP/2, and HTTP/3,
with a matching composable client. It ships several companion apps
(livery_s3, livery_stripe, ...) that depend on `{livery, ...}` from hex.

The goal is gRPC support, shipped as a new companion app `livery_grpc`
that depends on `livery`. It must cover server side and client side, let
Erlang developers expose and call services by writing only Erlang (gRPC
is the transport, ideally feeling like `erpc`), use battle-tested message
handling, compile `.proto` to Erlang modules at build time, and have all
four streaming modes working and tested.

### Why livery already fits gRPC

gRPC is HTTP/2 + length-prefixed protobuf frames + status in trailers.
Livery's `h2` dependency provides both sides of exactly that:

- Client API (`_build/default/lib/h2/src/h2.erl`): `connect/2,3`,
  `request/2..5`, `send_data/3,4`, `send_trailers/3`,
  `set_stream_handler/3,4`, `cancel/2,3`, `wait_connected/1,2`. Client
  events arrive as `{h2, Conn, {response|data|trailers|stream_reset|
  goaway|closed, ...}}`.
- Server: `livery_h2` (`src/livery_h2.erl`) already spawns a per-stream
  worker, translates `{h2, Conn, {data|trailers|...}}` into the
  `{livery_body, Ref, _}` reader protocol, supports trailers
  (`capabilities/1` reports `trailers => true`), and emits via
  `livery:emit/3`.
- `livery:emit/3` (`src/livery.erl`) already writes a `{chunked,
  Producer}` body plus trailers, which server-streaming maps onto.
- The WebSocket-over-h2 handoff (`livery_h2:accept_ws/4` ->
  `ws:accept/5` with `livery_ws_h2`, returning the `taken_over` sentinel
  resp from `livery_ws:upgrade/3`) is the template for the stream
  takeover that client-streaming and bidi need.

Hackney (the default client transport) is NOT used: it cannot send
request trailers or do bidi. The gRPC client runs on the `h2` client.

### Confirmed decisions

- Protobuf: `gpb` + `rebar3_gpb_plugin`; build-time `.proto` compilation.
- Streaming: all four call types in v1 (unary, server-stream,
  client-stream, bidi), phased.
- Extra surface in scope: reflection, health, gRPC-Web, gzip compression.
- Client transport: livery `h2` client.

## Blocking dependency: h2 bidi contract (GATE)

Bidi and client-streaming require capabilities `h2` does not yet have.
This is being worked in parallel on the `h2` library. **Implementation of
the bidi-dependent work pauses until the h2 bidi contract below is
delivered and accepted.**

Phases that can proceed now (current `h2` is sufficient):

- Phase 0 scaffold, Phase 1 wire layer, Phase 2 codegen.
- Phase 3 server unary + server-streaming (server already owns the stream
  via the `livery_h2` worker; server-streaming uses the `{chunked, ...}`
  emit path).
- Phase 4 client unary + server-streaming (client receives
  response/data/trailers on the owner pid, which current `h2` supports).

Phases gated on the contract (do not start until accepted):

- Phase 5 client-streaming + bidi.
- The bidi parts of the interop/compliance suite.

### h2 bidi contract (the artifact this gate waits on)

Grounded in current `h2` behavior: client `{response}`
(`h2_connection.erl:1389`), `{trailers}` (1325), and `{data}` go to the
connection owner; only buffered DATA replays to a per-stream handler.
`maybe_send_window_update` (2003) auto-refills the recv window per DATA
frame. `handle_send_data` (2406) buffers and flushes on WINDOW_UPDATE.

1. **Per-stream event routing, all event types.** `set_stream_handler`
   must route `response`, `data`, `trailers`, and `stream_reset` for that
   stream to the handler pid, buffering and replaying in order anything
   that arrived before registration. Today only DATA reaches the handler.
2. **Client streaming send + half-close.** After
   `send_request_headers(Conn, Headers, false)` -> `{ok, StreamId}`,
   repeated `send_data(_, _, _, false)` then a final `Fin=true` half-close
   the send side while receive stays open for response DATA and trailers.
3. **Server interleaved send/receive.** After `send_response`, repeated
   `send_data` plus terminal `send_trailers` while still receiving inbound
   request DATA on the same stream; neither direction blocks the other.
4. **Receive-side backpressure.** A bounded mode that does not auto-refill
   the stream recv window on dispatch; expose `consume/3` (or
   `update_window/3`) so WINDOW_UPDATE is gated on consumer progress.
5. **Send-side backpressure.** Define `send_data` behavior on send-window
   exhaustion: block with a timeout (`{error, timeout}`) or return
   `{error, flow}`; no unbounded buffering. Deterministic and tested.
6. **Cancellation/teardown per stream.** `cancel/2` from either side emits
   RST_STREAM and the peer's handler receives `{stream_reset, _, Code}`;
   the handler pid (not just the owner) is told of `goaway`/`closed` for
   its stream.
7. **Per-stream ownership.** Many concurrent calls multiplex one
   connection via per-stream handlers; an exiting call process must not
   take down the connection or sibling streams; `controlling_process` not
   required per call.

Acceptance: loopback test exchanging interleaved messages both ways on one
stream with client half-close and server trailers, plus tests for items
4, 5, and mid-stream cancel from each side. Existing client/server and
WebSocket-over-h2 (extended CONNECT) APIs unchanged.

## Reused livery building blocks

- `livery:start_service/1`, `livery:router_handler/2`, `livery:emit/3`
  (`src/livery.erl`), `livery_service:service_opts()` for serving.
- `livery_req` body reader (`{stream, Reader}`) and `livery_body` for
  reading inbound frames; `livery_resp:resp()` `{chunked, Producer}` +
  trailers for server-streaming.
- `livery_h2:accept_ws/4` pattern for stream takeover (bidi/client-stream).
- `livery_client` layer/stack shape mirrored for client interceptors.
- Livery's gzip codec (`livery_codec_gzip`) for `grpc-encoding`.
- `h2` client and server API as the wire engine.

## New application layout (`livery_grpc`)

Standard OTP app matching the other companions: `rebar.config` (deps
`{livery, ...}`, `{gpb, ...}`; plugin `rebar3_gpb_plugin`; Apache-2.0),
`src/livery_grpc.app.src`, AGENTS.md, CHANGELOG.md, README, Makefile,
docs/, test/, examples/ (with a sample `.proto`).

### Modules

- `livery_grpc_frame` - length-prefixed framing: 1-byte compressed flag +
  4-byte big-endian length + payload; a streaming decoder that buffers
  partial frames across h2 DATA boundaries and yields whole messages.
- `livery_grpc_codec` - encode/decode glue over the generated gpb module;
  one path shared by `+proto` and (later) `+json` content types.
- `livery_grpc_compression` - `identity` + `gzip` via
  `grpc-encoding`/`grpc-accept-encoding`, reusing livery's gzip codec.
- `livery_grpc_status` - the 16 canonical codes as atoms, mapped to/from
  `grpc-status`/`grpc-message`, plus `grpc-status-details-bin`. Always
  HTTP 200; errors via trailers or a trailers-only response.

  Trailers-only handling needs care: `livery:emit/3` drops trailers when
  the body is `empty` (`src/livery.erl:220` sends headers with
  `end_stream => true` and ignores trailers). Two deliberate shapes:
  - True gRPC Trailers-Only (single HEADERS block): put `grpc-status` /
    `grpc-message` directly in the response headers and end the stream.
    Use this for the fast-error path. Build it as a `livery_resp` whose
    headers already carry the status, with an `empty` body.
  - Normal response with no message but real trailers: use `{full, <<>>}`
    with trailers, which hits the `0 ->` clause at `src/livery.erl:228`
    and forces a separate trailing HEADERS block.

  The server must never reach the `empty`-body-plus-trailers path
  expecting the trailers to be emitted; pick one of the two shapes
  explicitly per response.
- `livery_grpc_codegen` - generates, per service, a `*_grpc.erl`:
  service name; per-method input/output type and streaming kind; a
  `livery_grpc_service` behaviour (one callback per method); an
  erpc-style client stub (`Method(Conn, Msg, Opts)` for unary, stream
  handles for streaming). Built from gpb's service introspection (or a
  small protoc plugin), wired as a rebar3 provider so it runs after
  `rebar3_gpb_plugin`.
- `livery_grpc` - facade. Primary API is a dedicated gRPC listener:
  `start_link(Opts)` / `start_server(Opts)` starts an h2 listener (its
  own port, TLS or h2c) whose handler is always the gRPC dispatcher. One
  listener serves only gRPC, so there is no path/middleware mixing with
  REST routes and the dispatcher owns every stream from the start, which
  keeps bidi takeover clean. Built on `livery_h2`/`livery:start_service`
  with only an `https`/`http` listener, so livery middleware is still
  available as interceptors. `Opts` carries `services`, `port`,
  `transport`, TLS material, and `compression`. (A raw `handler(Services)`
  that returns a livery handler stays available as an advanced escape
  hatch for mounting gRPC onto a shared service, but it is not the
  recommended path.)
- `livery_grpc_server` - matches `POST /package.Service/Method`,
  validates `content-type`, reads request frames, dispatches to the
  callback module, writes response frames, emits status trailers. Unary
  and server-stream use the worker + `{chunked, Producer}` path;
  client-stream and bidi take over the h2 stream (the `accept_ws/4`
  pattern) with a process that reads and writes concurrently.
- `livery_grpc_client` - `connect(Host, Port, Opts)` over the h2 client
  (TLS/h2c, connection reuse), `grpc-timeout` deadlines, metadata
  headers. Unary `call/5 -> {ok, Reply} | {error, {Status, Message}}`;
  streaming returns a handle with `send/2`, `recv/1,2`, `close_send/1`.
- `livery_grpc_reflection` - serves `grpc.reflection.v1` from runtime
  descriptors (grpcurl/Postman discovery).
- `livery_grpc_health` - serves `grpc.health.v1`, paired with livery
  health checks.
- gRPC-Web - alternate framing path (binary + base64) over HTTP/1.1 and
  HTTP/2, sharing codec and dispatch, exposed as an alternate handler.

## Developer experience (erpc parity)

- Expose: developer implements the generated `livery_grpc_service`
  behaviour (one Erlang function per RPC), then mounts it with
  `livery_grpc:start_server(#{services => [my_service]})` or onto an
  existing `livery:start_service/1`.
- Call: `myservice_grpc:get_user(Conn, Req)` reads like `erpc:call/4`;
  under the hood it is `livery_grpc_client:call/5`.

## Phases

0. Scaffold: app skeleton, deps, gpb plugin wiring, example `.proto`, CI
   green with an empty service.
1. Wire layer: `livery_grpc_frame`, `_codec`, `_status`, content types,
   `_compression`, with property tests.
2. Codegen: descriptors, behaviour, client stubs from gpb.
3. Server unary + server-streaming on the h2 worker path.
4. Client unary + server-streaming on the h2 client.
5. [GATED on h2 bidi contract] Client-streaming + bidi via h2 stream
   takeover, both sides.
6. Cross-cutting: deadlines, metadata, error details, interceptors mapped
   to livery middleware.
7. Reflection, health, gRPC-Web.
8. Interop and compliance tests, docs, examples (bidi cases gated on the
   h2 contract).

## Verification

- Property tests (proper) on `livery_grpc_frame`: round-trip, large
  messages, fragmentation across arbitrary chunk boundaries, compressed
  and not; `livery_grpc_status` round-trip and trailers-only errors.
- In-tree interop CT suite: livery_grpc client vs livery_grpc server over
  loopback h2 for all four call types, plus deadlines, metadata,
  compression, cancellation (client `cancel`, server `RST_STREAM`,
  deadline expiry, mid-stream disconnect).
- External compliance: `grpcurl` against the server (reflection + sample
  service); optionally a Go or Python client in CI for cross-stack proof.
- `rebar3 ct`, `rebar3 dialyzer`, `rebar3 lint`, `rebar3 ex_doc`, and a
  runnable example under `examples/`.

## Open questions (default if unanswered)

- gpb messages as maps (preferred, matches livery's map-first style) vs
  records (gpb default).
- Cross-stack CI matrix scope (which external clients, if any).

Resolved: gRPC gets its own dedicated listener (simpler); mounting onto a
shared service is an advanced escape hatch, not the default.
