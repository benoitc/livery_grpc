# Testing

Test gRPC handlers by running a real server on an ephemeral port and
calling it with the client. This guide shows the in-tree approach, the
end-to-end suite, and external checks with grpcurl.

## Test against a real server

Start a server on port 0, read the bound port, and drive it with the
client. This works in eunit:

```erlang
start() ->
    {ok, _} = application:ensure_all_started(livery_grpc),
    {ok, Server} = livery_grpc:start_server(#{
        port => 0, services => [#{proto => greeter_pb, service => 'Greeter', handler => my_greeter}]
    }),
    #{server => Server, port => livery_grpc:server_port(Server)}.

stop(#{server := Server}) ->
    ok = livery_grpc:stop_server(Server).

unary(#{port := Port}) ->
    fun() ->
        {ok, Conn} = livery_grpc_client:connect("localhost", Port),
        {ok, M}    = livery_grpc_client:method(greeter_pb, 'Greeter', 'SayHello'),
        ?assertEqual({ok, #{message => <<"hello ada">>}},
                     livery_grpc_client:call(Conn, M, #{name => <<"ada">>})),
        livery_grpc_client:close(Conn)
    end.
```

Connect inside each test process: the connection's events are delivered to
the process that opened it, so a connection opened in an eunit setup that
runs in a different process will not be reachable from the test bodies.

Because the listener is supervised, it survives a short-lived test setup.

## End-to-end suite

livery_grpc's own `livery_grpc_e2e_SUITE` (Common Test) boots one server
and exercises the full journey two ways: with the in-tree client, and with
grpcurl over reflection. It is a good template for a project-level e2e
suite. Run it with `rebar3 ct`.

## External checks with grpcurl

With `reflection => true`, grpcurl tests your server as a real external
client, no `.proto` needed:

```
$ grpcurl -plaintext localhost:50051 list
$ grpcurl -plaintext -d '{"name":"ada"}' localhost:50051 greeter.Greeter/SayHello
```

`make interop` in livery_grpc runs a grpcurl smoke test against a running
server and is skipped if grpcurl is not installed.

## See also

- [Getting started](../getting-started.md), [Reflection](reflection.md).
