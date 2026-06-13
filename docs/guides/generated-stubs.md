# Generated stubs

The generic client (`livery_grpc_client:call/3`) works for any method.
Generated stubs add a typed call per RPC, so a service reads as plain
Erlang, and a behaviour the compiler can check your handler against. They
are optional sugar.

## Generate

```
$ make stubs PROTO=greeter_pb
```

or from Erlang:

```erlang
livery_grpc_codegen:generate(greeter_pb, "gen").
```

This writes, per service, two modules:

- `<service>_client` -- one function per RPC.
- `<service>_service` -- a behaviour with one `-callback` per RPC.

## Use the client stub

```erlang
{ok, Reply}   = greeter_client:say_hello(Conn, #{name => <<"ada">>}),
{ok, Replies} = greeter_client:say_hello_stream(Conn, #{name => <<"ada">>}),
{ok, Reply2}  = greeter_client:say_hello_collect(Conn, [Req1, Req2]),
{ok, Call}    = greeter_client:say_hello_chat(Conn).   %% a streaming handle
```

Unary and server-streaming take `(Conn, Request)`; client-streaming takes
`(Conn, Requests)`; bidirectional takes `(Conn)` and returns a handle to
drive with `send/2`, `recv/1`, `send_end/1`.

## Use the service behaviour

Declare it in your handler so the compiler and dialyzer check the
callbacks:

```erlang
-module(my_greeter).
-behaviour(greeter_service).
-export([say_hello/2, say_hello_stream/3, say_hello_collect/2, say_hello_chat/2]).
```

## Notes

- Stubs resolve the method descriptor at call time, so they stay correct
  if you recompile the proto.
- Generated modules are reproducible; you can commit them or regenerate in
  the build, whichever your project prefers.
