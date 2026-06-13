# Compression

livery_grpc compresses messages with gzip, negotiated through the
`grpc-encoding` and `grpc-accept-encoding` headers. The default is
`identity` (no compression).

## Compress server replies

Set `compression => gzip` when starting the server. Replies are gzipped
and advertised with `grpc-encoding: gzip`.

```erlang
livery_grpc:start_server(#{
    port        => 50051,
    services    => Services,
    compression => gzip
}).
```

## Compress client requests

Set `compression => gzip` in the call options. The request is gzipped and
marked accordingly; the client always advertises that it accepts gzip
replies.

```erlang
livery_grpc_client:call(Conn, Method, Request, #{compression => gzip}).
```

Each side decompresses per the message's frame flag and `grpc-encoding`, so
a compressed request and an identity reply (or the reverse) both work.

## Notes

- Compression is per message. A frame carries a flag saying whether its
  payload is compressed, and the flag wins over the negotiated algorithm.
- gzip helps on large or repetitive messages; for small payloads the
  overhead is not worth it. Measure.
