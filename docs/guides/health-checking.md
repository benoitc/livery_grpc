# Health checking

livery_grpc ships the standard `grpc.health.v1.Health` service, so load
balancers and orchestrators can probe your server with the protocol they
already speak.

## Mount the service

Add `livery_grpc_health:service()` to the server's service list:

```erlang
livery_grpc:start_server(#{
    port     => 50051,
    services => [MyService, livery_grpc_health:service()]
}).
```

## Set status

Status is per service name. The empty name (`<<>>`) is the overall server
and defaults to `SERVING`. Set named services as they come up and down:

```erlang
livery_grpc_health:set_serving(<<"myapp.Greeter">>),
livery_grpc_health:set_not_serving(<<"myapp.Greeter">>),
livery_grpc_health:set_not_serving().   %% the whole server
```

## Check and watch

`Check` is a unary call returning the current status:

```
$ grpcurl -plaintext -d '{"service":""}' localhost:50051 grpc.health.v1.Health/Check
{ "status": "SERVING" }
```

`Watch` is server-streaming: it sends the current status and then a new
message every time it changes, until the client disconnects. From Erlang,
drive it with the streaming client (`open/2` + `recv/1`).

## Notes

- `Check` on a named service that was never set returns `NOT_FOUND`;
  `Watch` returns `SERVICE_UNKNOWN` and keeps watching, so the client
  learns when the service appears.
- On drain, call `set_not_serving()` before stopping so probes see the
  server leave rotation. See [graceful shutdown](graceful-shutdown.md).
