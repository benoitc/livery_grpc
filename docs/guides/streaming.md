# Streaming

gRPC has four call types. This guide shows each one on the server and the
client. Messages are maps throughout.

## Unary

One request, one reply. The handler returns `{ok, Reply}` or an error.

```erlang
say_hello(#{name := Name}, _Ctx) ->
    {ok, #{message => <<"hello ", Name/binary>>}}.
```

```erlang
{ok, Reply} = livery_grpc_client:call(Conn, Method, #{name => <<"ada">>}).
```

## Server-streaming

One request, a stream of replies. The handler gets a `Send` function and
returns `ok` when done.

```erlang
say_hello_stream(#{name := Name}, Send, _Ctx) ->
    [Send(#{message => <<"hi ", Name/binary, $\s, (integer_to_binary(I))/binary>>})
     || I <- lists:seq(1, 3)],
    ok.
```

The client collects the replies into a list:

```erlang
{ok, Replies} = livery_grpc_client:call(Conn, Method, #{name => <<"ada">>}).
```

## Client-streaming

A stream of requests, one reply. The handler reads the requests through a
stream handle and returns a single reply.

```erlang
collect(Stream, _Ctx) ->
    {ok, Requests, _Stream} = livery_grpc_stream:recv_all(Stream),
    {ok, summarize(Requests)}.
```

The client sends a list and gets one reply:

```erlang
{ok, Reply} = livery_grpc_client:client_stream(Conn, Method, [Req1, Req2, Req3]).
```

For finer control (send as you go), use `open/2` then `send/2` and
`send_end/1`.

## Bidirectional

Both sides stream, independently. The handler reads with `recv/1` and
replies with `send/2`, interleaved, and returns `ok` when the client is
done.

```erlang
chat(Stream, _Ctx) ->
    loop(Stream).

loop(Stream) ->
    case livery_grpc_stream:recv(Stream) of
        {ok, Msg, Stream1} ->
            livery_grpc_stream:send(Stream1, reply_for(Msg)),
            loop(Stream1);
        {eof, _Stream1} ->
            ok
    end.
```

The client opens a call and drives it:

```erlang
{ok, Call} = livery_grpc_client:open(Conn, Method),
ok = livery_grpc_client:send(Call, #{...}),
{ok, Reply, Call1} = livery_grpc_client:recv(Call),
ok = livery_grpc_client:send_end(Call1).   %% half-close when done sending
```

`recv/1` returns `{ok, Reply, Call}` per message, `{eof, Outcome, Call}`
when the server finishes (carrying the final status), or
`{error, Reason, Call}`.

## Notes

- Reading and writing happen in the one handler process, so a
  bidirectional handler can interleave `recv/1` and `send/2` freely.
- gRPC-Web supports unary and server-streaming only; client-streaming and
  bidirectional need gRPC over HTTP/2. See [gRPC-Web](grpc-web.md).
- For backpressure on large streams, see [flow control](flow-control.md).
