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

A streaming handler that reads the request stream sees a cancel or reset
as an error from `recv/1`, so the same loop that reads requests also stops
on cancel:

```erlang
loop(Stream) ->
    case livery_grpc_stream:recv(Stream) of
        {ok, Msg, Stream1}         -> handle(Msg), loop(Stream1);
        {eof, _Stream1}            -> ok;   %% client half-closed normally
        {error, _Reason, _Stream1} -> ok    %% client cancelled or reset
    end.
```

A handler that does not read the request stream, such as a
server-streaming push like health `Watch`, instead receives a message and
can match it:

```erlang
receive
    {livery_disconnect, _Ref, _Reason} -> ok;
    ...
end
```

For work that does not touch a mailbox at all, register a cancel callback
with `livery_req:on_disconnect/2` (the request is in the call context
under `req`).

## Notes

- Cancellation is best-effort: in-flight work already sent may still
  arrive.
- A `deadline_exceeded` is a server-enforced cancellation; see
  [deadlines](deadlines.md).
