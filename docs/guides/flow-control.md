# Flow control

Flow control stops a fast sender from overwhelming a slow receiver. gRPC
runs over HTTP/2, which has built-in flow control per stream; livery_grpc
streaming builds on it.

## How it works here

A streaming handler reads one message at a time with
`livery_grpc_stream:recv/1` and replies with `send/2`. Because the handler
pulls each message, it sets the pace: it only asks for the next request
after handling the current one, and the underlying HTTP/2 layer (h2 0.10)
applies receive-window backpressure based on that progress rather than
buffering an unbounded amount.

```erlang
loop(Stream) ->
    case livery_grpc_stream:recv(Stream) of
        {ok, Msg, Stream1} ->
            ok = handle(Msg),       %% slow work here naturally slows intake
            loop(Stream1);
        {eof, _} ->
            ok
    end.
```

On the send side, the HTTP/2 layer bounds how much unacknowledged data is
buffered; a producer that outruns the peer is slowed rather than allowed to
grow memory without limit.

## Guidance

- Prefer pulling one message at a time (`recv/1`) over draining everything
  (`recv_all/1`) when the stream is large or unbounded, so backpressure can
  do its job.
- Do the per-message work in the handler loop, not in a spawned process
  that you feed without limit; the loop is the throttle.

## See also

- [Streaming](streaming.md) for the call shapes.
