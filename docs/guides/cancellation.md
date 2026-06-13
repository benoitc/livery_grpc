# Cancellation

A client cancels a call when it no longer needs the result. The server is
told, so it can stop work. This guide shows both sides.

## Cancel from the client

A unary call is bounded by its [deadline](deadlines.md); set one and it is
cancelled automatically when it overruns.

For a streaming call, cancel the open handle:

```erlang
{ok, Call} = livery_grpc_client:open(Conn, Method),
...
ok = livery_grpc_client:cancel(Call).
```

`cancel/1` resets the stream (HTTP/2 `RST_STREAM`). Closing the whole
connection with `close/1` cancels every call on it.

## See it on the server

When a client cancels, resets the stream, or disconnects, livery delivers
a message to the handler process:

```erlang
{livery_disconnect, _Ref, _Reason}
```

A streaming handler that runs a `receive` loop can match it and stop:

```erlang
loop(Stream) ->
    receive
        {livery_disconnect, _, _} -> ok
    after 0 ->
        case livery_grpc_stream:recv(Stream) of
            {ok, Msg, Stream1} -> handle(Msg), loop(Stream1);
            {eof, _}           -> ok
        end
    end.
```

For work that does not poll a mailbox, register a cancel callback with
`livery_req:on_disconnect/2` (the request is in the call context under
`req`).

## Notes

- Cancellation is best-effort: in-flight work already sent may still
  arrive.
- A `deadline_exceeded` is a server-enforced cancellation; see
  [deadlines](deadlines.md).
