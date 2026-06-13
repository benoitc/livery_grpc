# Authentication

This guide covers the two common pieces of gRPC authentication: encrypting
the channel with TLS, and authenticating the caller with a token in
metadata.

## Serve over TLS

Pass `transport => ssl` with a certificate and key. ALPN negotiates h2.

```erlang
livery_grpc:start_server(#{
    port      => 443,
    transport => ssl,
    cert      => "priv/cert.pem",
    key       => "priv/key.pem",
    services  => Services
}).
```

The client connects with `transport => ssl`:

```erlang
{ok, Conn} = livery_grpc_client:connect("api.example.com", 443, #{transport => ssl}).
```

For local development the default `tcp` transport speaks h2c (plaintext
HTTP/2), which is what `grpcurl -plaintext` and the examples use.

## Authenticate with a token

Send a bearer token in metadata (see [metadata](metadata.md)):

```erlang
livery_grpc_client:call(Conn, Method, Request, #{
    metadata => [{<<"authorization">>, <<"Bearer ", Token/binary>>}]
}).
```

Check it on the server. Read the token from the context metadata and
return `{error, {unauthenticated, _}}` when it is missing or invalid:

```erlang
say_hello(Request, #{metadata := Md}) ->
    case authorized(Md) of
        true  -> {ok, reply(Request)};
        false -> {error, {unauthenticated, <<"invalid token">>}}
    end.
```

To cover every method without repeating the check, factor it into a helper
the handlers call, or run a server interceptor (livery middleware) that
validates the token and either calls `Next(Req)` or returns a gRPC error
response. Returning the status from the handler is the simplest path and
produces the right result on both gRPC and gRPC-Web framings.

## Notes

- Use livery's existing auth middleware (bearer, JWKS, introspection) to
  validate tokens, then enforce the decision where it is convenient.
- Authenticate over TLS in production; a bearer token on a plaintext
  connection is exposed.

## See also

- [Metadata](metadata.md), [Interceptors](interceptors.md).
