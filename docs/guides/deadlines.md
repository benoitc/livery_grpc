# Deadlines

A deadline bounds how long a call may take. The client sets it, it travels
on the wire as `grpc-timeout`, and the server enforces it. Always set one:
without it a stuck backend ties up the caller indefinitely.

## Set a deadline on a call

Pass `deadline` (milliseconds) in the call options:

```erlang
livery_grpc_client:call(Conn, Method, Request, #{deadline => 5000}).
```

The client sends `grpc-timeout` and bounds its own wait by the deadline.
If the deadline passes first, the call returns
`{error, {deadline_exceeded, _}}`.

## Enforce it on the server

The deadline is in the call context, and a unary handler that overruns is
aborted with `deadline_exceeded`:

```erlang
slow(Request, #{deadline := Deadline}) ->
    %% Deadline is the remaining time in ms, or infinity.
    ...
```

A streaming handler should check the deadline itself for long-running
work, since it owns its loop.

## Notes

- A deadline is an absolute bound on the whole call, not a per-message
  timeout.
- Prefer deadlines over the connection-level `timeout` option; the
  deadline is also communicated to the server, which can stop work early.

## See also

- [Cancellation](cancellation.md) to stop a call before its deadline.
