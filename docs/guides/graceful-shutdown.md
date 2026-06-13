# Graceful shutdown

Shut a server down without dropping calls that are mid-flight: stop
advertising as healthy, give in-flight work a moment to finish, then stop
the listener.

## Stop a server

`stop_server/1` stops the listener and its supervised owner:

```erlang
ok = livery_grpc:stop_server(Server).
```

## Drain first

If you serve health checks, mark the server not-serving before stopping so
load balancers take it out of rotation, then pause for in-flight calls to
finish:

```erlang
livery_grpc_health:set_not_serving(),     %% probes now see NOT_SERVING
timer:sleep(DrainMs),                      %% let in-flight calls complete
ok = livery_grpc:stop_server(Server).
```

`DrainMs` should cover your longest expected unary call (streaming calls
are bounded by their own deadlines or by the client).

## In a supervision tree

If you started the server from your application's `start/2`, it stops when
the application stops. To drain, do the health flip and pause in your
application's `prep_stop/1` or a dedicated shutdown step before the
supervisor terminates.

## See also

- [Health checking](health-checking.md) for the status a balancer reads.
- [Deadlines](deadlines.md) bound how long in-flight calls can run.
