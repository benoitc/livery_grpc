# gRPC-Web

gRPC-Web lets browsers call gRPC services. It carries the same messages but
puts the status in an in-body trailer frame instead of HTTP trailers, so it
works over HTTP/1.1 and through proxies. livery_grpc serves it on the same
server, with no extra configuration.

## What works

A gRPC-Web request is recognized by its content type and handled by the
same service callbacks as native gRPC. Both framings are supported:

- `application/grpc-web` / `application/grpc-web+proto` (binary)
- `application/grpc-web-text` (base64)

Unary and server-streaming are supported, which is what browsers use.
Client-streaming and bidirectional require gRPC over HTTP/2 and return
`unimplemented` over gRPC-Web.

## Using it

Nothing to enable: start a normal server and gRPC-Web requests just work.

```erlang
livery_grpc:start_server(#{port => 50051, services => Services}).
```

A browser client (for example grpc-web with `@grpc/grpc-web`) points at
the server and calls unary and server-streaming methods. The status
arrives as a trailer frame in the response body; livery_grpc writes it for
you.

## Notes

- Browsers cannot stream request bodies, which is why client-streaming and
  bidirectional are not available over gRPC-Web. Use server-streaming for
  push, or native gRPC from a non-browser client.
- gRPC-Web is often terminated at a proxy (Envoy) in front of a native
  gRPC server; livery_grpc removes that need by speaking both directly.
