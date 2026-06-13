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

Check it on the server. The cleanest place is a server interceptor (livery
middleware), so every method is covered and the handler stays focused on
business logic:

```erlang
-module(auth_mw).
-behaviour(livery_middleware).
-export([call/3]).

call(Req, Next, _State) ->
    case bearer_token(livery_req:header(<<"authorization">>, Req)) of
        {ok, _Claims} -> Next(Req);
        error         -> livery_grpc_server:... %% see note
    end.
```

Or check inside a handler from the context metadata and return
`{error, {unauthenticated, _}}` when it is missing or invalid:

```erlang
say_hello(Request, #{metadata := Md}) ->
    case authorized(Md) of
        true  -> {ok, reply(Request)};
        false -> {error, {unauthenticated, <<"invalid token">>}}
    end.
```

## Notes

- A rejecting middleware should produce a gRPC-shaped response. The
  simplest, transport-agnostic approach is to authenticate in the handler
  and return `{error, {unauthenticated, _}}`, which becomes the right
  status on every framing (gRPC and gRPC-Web).
- Use livery's existing auth middleware (bearer, JWKS, introspection) for
  token validation, then enforce in the handler.

## See also

- [Metadata](metadata.md), [Interceptors](interceptors.md).
