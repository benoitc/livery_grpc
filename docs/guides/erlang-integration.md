# Integrate gRPC into your Erlang app

This guide adds livery_grpc to an existing Erlang/OTP application: the
build setup, where generated code goes, how to start a server in your
supervision tree, and how to call services from your own code. For the
architecture behind it, see [Design](../design.md).

## Add the dependency

In `rebar.config`:

```erlang
{deps, [
    {livery_grpc, "0.1.0"}
]}.
```

livery_grpc pulls in `livery` and `gpb`. Add the build plugin and point it
at your protos:

```erlang
{plugins, [{rebar3_gpb_plugin, "3.0.1"}]}.

{gpb_opts, [
    {i, "proto"},
    {module_name_suffix, "_pb"},
    {o_erl, "src"},
    {strings_as_binaries, true},
    {maps, true},
    {maps_unset_optional, omitted},
    type_specs,
    descriptor            %% needed only if you enable reflection
]}.

{provider_hooks, [
    {pre, [{compile, {protobuf, compile}}, {clean, {protobuf, clean}}]}
]}.
```

## Lay out your protos

Put `.proto` files in `proto/`. `rebar3 compile` generates one `*_pb`
module per file (here into `src/`). Messages are maps. Keep the generated
`*_pb` modules out of strict style checks: a generated module is not
hand-written.

## Implement a service

One module, one snake_case function per RPC:

```erlang
-module(my_greeter).
-export([say_hello/2]).

say_hello(#{name := Name}, _Ctx) ->
    {ok, #{message => <<"hello ", Name/binary>>}}.
```

## Start a server in your supervision tree

`livery_grpc:start_server/1` returns the listener's owner pid, and the
listener is already supervised inside the `livery_grpc` application. The
simplest integration is to start it from your application's `start/2`:

```erlang
start(_Type, _Args) ->
    {ok, _Server} = livery_grpc:start_server(#{
        port     => 50051,
        services => [#{proto => greeter_pb, service => 'Greeter', handler => my_greeter}]
    }),
    my_app_sup:start_link().
```

If you prefer to own the lifecycle yourself, keep the returned pid and call
`livery_grpc:stop_server/1` on shutdown. Pass `transport => ssl` with
`cert` and `key` for TLS, `reflection => true` for discovery, and
`middleware => Stack` to run livery middleware as interceptors.

## Share state with handlers

Handlers are stateless modules. Reach shared resources (a pool, an ETS
table, config) the way any Erlang code does: a registered name, a
`persistent_term`, or a started process. The call context also carries the
request metadata and deadline if you need them.

## Call services from your code

Open a connection once and reuse it; make calls from the process that owns
it:

```erlang
{ok, Conn} = livery_grpc_client:connect("api.internal", 50051),
{ok, M}    = livery_grpc_client:method(greeter_pb, 'Greeter', 'SayHello'),
{ok, Reply} = livery_grpc_client:call(Conn, M, #{name => <<"ada">>}).
```

For an `erpc`-style API, generate stubs with `make stubs` (or
`livery_grpc_codegen:generate/2`) and call `greeter_client:say_hello(Conn,
Req)`. See [generated stubs](generated-stubs.md).

## Test your handlers

Start a server on port 0, get the bound port, and drive it with the
client. See the [testing guide](testing.md).

## See also

- [Design](../design.md) for the runtime and the reasoning behind it.
- [Getting started](../getting-started.md) for a from-scratch walkthrough.
