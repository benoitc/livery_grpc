-module(greeter_example).
-moduledoc """
A runnable Greeter over the helloworld service.

Start a server and call it from the same node:

```
$ rebar3 as examples shell
1> greeter_example:run().
```

Or start the server and drive it with grpcurl:

```
$ rebar3 as examples shell
1> greeter_example:start(50051).
$ grpcurl -plaintext -proto proto/helloworld.proto \\
    -d '{"name":"ada"}' localhost:50051 helloworld.Greeter/SayHello
```
""".

%% gRPC service callbacks (one Erlang function per RPC, snake_case).
-export([say_hello/2, say_hello_stream/3, say_hello_collect/2, say_hello_chat/2]).
%% Demo helpers.
-export([start/1, run/0]).

%%====================================================================
%% Service callbacks
%%====================================================================

say_hello(#{name := Name}, _Ctx) ->
    {ok, #{message => <<"hello ", Name/binary>>}}.

say_hello_stream(#{name := Name}, Send, _Ctx) ->
    lists:foreach(
        fun(I) ->
            N = integer_to_binary(I),
            Send(#{message => <<"hello ", Name/binary, " #", N/binary>>})
        end,
        lists:seq(1, 3)
    ),
    ok.

%% Client-streaming: collect all names, reply once.
say_hello_collect(Stream, _Ctx) ->
    {ok, Requests, _Stream1} = livery_grpc_stream:recv_all(Stream),
    Names = [N || #{name := N} <- Requests],
    {ok, #{message => <<"hello ", (iolist_to_binary(lists:join(<<", ">>, Names)))/binary>>}}.

%% Bidirectional: echo a greeting per request.
say_hello_chat(Stream, _Ctx) ->
    case livery_grpc_stream:recv(Stream) of
        {ok, #{name := Name}, Stream1} ->
            _ = livery_grpc_stream:send(Stream1, #{message => <<"hi ", Name/binary>>}),
            say_hello_chat(Stream1, undefined);
        {eof, _Stream1} ->
            ok;
        {error, _Reason, _Stream1} ->
            {error, internal}
    end.

%%====================================================================
%% Demo
%%====================================================================

-doc "Start a Greeter server on `Port` (h2c).".
-spec start(inet:port_number()) -> {ok, livery_grpc:server()} | {error, term()}.
start(Port) ->
    {ok, _} = application:ensure_all_started(livery_grpc),
    livery_grpc:start_server(#{
        port => Port,
        services => [#{proto => helloworld_pb, service => 'Greeter', handler => ?MODULE}]
    }).

-doc "Start a server, call it as a client, print the replies, and stop.".
-spec run() -> ok.
run() ->
    {ok, Server} = start(0),
    Port = livery_grpc:server_port(Server),
    {ok, Conn} = livery_grpc_client:connect("localhost", Port),
    try
        {ok, Unary} = livery_grpc_client:method(helloworld_pb, 'Greeter', 'SayHello'),
        io:format("unary: ~p~n", [livery_grpc_client:call(Conn, Unary, #{name => <<"ada">>})]),
        {ok, Stream} = livery_grpc_client:method(helloworld_pb, 'Greeter', 'SayHelloStream'),
        io:format("stream: ~p~n", [livery_grpc_client:call(Conn, Stream, #{name => <<"sam">>})])
    after
        livery_grpc_client:close(Conn),
        livery_grpc:stop_server(Server)
    end,
    ok.
