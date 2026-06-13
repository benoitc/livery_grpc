# Reflection

Server reflection lets tools discover your services and message schemas at
runtime, so clients like grpcurl and Postman work without a local
`.proto`. livery_grpc serves `grpc.reflection.v1`.

## Enable it

Pass `reflection => true`:

```erlang
livery_grpc:start_server(#{
    port       => 50051,
    reflection => true,
    services   => Services
}).
```

This mounts the reflection service and builds a descriptor set from every
registered service (including health and reflection itself). The
descriptors come from gpb, so enable its `descriptor` option in
`gpb_opts`.

## Use it

With reflection on, grpcurl needs no `.proto`:

```
$ grpcurl -plaintext localhost:50051 list
grpc.health.v1.Health
grpc.reflection.v1.ServerReflection
myapp.Greeter

$ grpcurl -plaintext localhost:50051 describe myapp.Greeter
$ grpcurl -plaintext -d '{"name":"ada"}' localhost:50051 myapp.Greeter/SayHello
```

## Notes

- Reflection answers `list_services`, `file_by_filename`, and
  `file_containing_symbol`. Extensions are a proto2 feature and report
  not-found.
- It is convenient in development and for debugging. In locked-down
  production you may prefer to leave it off and distribute `.proto` files.
