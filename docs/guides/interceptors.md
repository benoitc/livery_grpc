# Interceptors

Interceptors run generic behavior around every call: logging, auth,
tracing, retries. livery_grpc has them on both sides, with the same shape
as livery's middleware and `livery_client` layers (Tower-style layers on
the BEAM).

## Server interceptors

A server interceptor is livery middleware. Pass a stack with the
`middleware` option; each entry runs around the gRPC handler.

```erlang
livery_grpc:start_server(#{
    port       => 50051,
    services   => Services,
    middleware => [{auth_mw, Config}, {access_log, []}]
}).
```

A middleware module implements `call(Req, Next, State)` and either calls
`Next(Req)` to continue or short-circuits. This is the standard
`livery_middleware` contract, so any livery middleware works as a gRPC
interceptor.

## Client interceptors

A client interceptor is a layer in a stack. Set it per connection
(`interceptors` on `connect/3`) or per call (`interceptors` in the call
options). Each entry is `{Module, State}` or
`fun((Request, Next) -> Result)`, the same shape as `livery_client`.

```erlang
{ok, Conn} = livery_grpc_client:connect(Host, Port, #{
    interceptors => [Trace, Logging]
}).
```

The request flowing through the stack is a map: `#{method, message,
metadata, opts}`. An interceptor may rewrite it, observe the result, or
short-circuit. Errors are threaded as values.

### Helpers

Three constructors build common interceptors:

```erlang
%% rewrite the request before the call
Trace = livery_grpc_client:before(fun(Req) ->
    livery_grpc_client:set_metadata([{<<"x-trace-id">>, new_id()}], Req)
end),

%% transform a successful reply
Tag = livery_grpc_client:after_response(fun({ok, Reply}) -> {ok, decorate(Reply)} end),

%% catch exceptions
Guard = livery_grpc_client:wrap(fun(_Class, _Reason, _Stack) ->
    {error, {internal, <<"client error">>}}
end).
```

## Notes

- Client interceptors run around unary and server-streaming calls (the
  `call/3,4` path). For streaming handles (`open/2`, `client_stream/4`),
  wrap the call site yourself.
- See [retry](retry.md) for a retry interceptor and
  [authentication](authentication.md) for a token-injecting one.
