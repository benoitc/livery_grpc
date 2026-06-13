# Wait for ready

Sometimes you want a client to wait for a server to come up rather than
fail immediately when it is not yet reachable, for example at startup when
services race to boot.

## Connect with retry

`livery_grpc_client:connect/2,3` fails with `{error, econnrefused}` if
nothing is listening yet. Retry with backoff until it succeeds (bounded, so
you do not loop forever):

```erlang
connect_ready(Host, Port, Opts, Deadline) ->
    case livery_grpc_client:connect(Host, Port, Opts) of
        {ok, Conn} ->
            {ok, Conn};
        {error, _} when erlang:monotonic_time(millisecond) < Deadline ->
            timer:sleep(200),
            connect_ready(Host, Port, Opts, Deadline);
        {error, _} = Err ->
            Err
    end.
```

Reuse the returned connection for many calls; you pay the wait once.

## Notes

- Set a [deadline](deadlines.md) on the calls themselves too: a connection
  that came up may still be slow.
- For per-call "wait until the server is ready", a [retry](retry.md)
  interceptor on `unavailable` covers transient unreadiness after the
  connection exists.
