# Metadata

Metadata is key-value pairs sent with a call, as HTTP/2 headers. Use it for
auth tokens, request ids, and tracing. This guide shows how to send it from
a client and read it in a handler.

## Send metadata from a client

Pass `metadata` in the call options. Keys and values are binaries:

```erlang
livery_grpc_client:call(Conn, Method, Request, #{
    metadata => [{<<"authorization">>, <<"Bearer ", Token/binary>>},
                 {<<"x-request-id">>, ReqId}]
}).
```

The same option works on `client_stream/4` and `open/3`. To set metadata
for every call on a connection, use a `before` interceptor (see
[interceptors](interceptors.md)):

```erlang
Trace = livery_grpc_client:before(fun(Req) ->
    livery_grpc_client:set_metadata([{<<"x-request-id">>, new_id()}], Req)
end),
{ok, Conn} = livery_grpc_client:connect(Host, Port, #{interceptors => [Trace]}).
```

## Read metadata in a handler

The call context carries the request metadata, with the gRPC and HTTP
framing headers removed:

```erlang
say_hello(Request, #{metadata := Metadata}) ->
    case lists:keyfind(<<"authorization">>, 1, Metadata) of
        {_, <<"Bearer ", Token/binary>>} -> ...;
        false -> {error, {unauthenticated, <<"missing token">>}}
    end.
```

## Notes

- Metadata keys are lowercased on the wire, per HTTP/2.
- Binary metadata (a `-bin` suffix) is base64 on the wire; send and read
  the already-encoded value, or use the status details path for
  structured errors (see [error handling](error-handling.md)).

## See also

- [Authentication](authentication.md) builds a token check on top of this.
- [Interceptors](interceptors.md) to add metadata across all calls.
