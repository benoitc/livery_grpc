-module(livery_grpc_client_tests).

-include_lib("eunit/include/eunit.hrl").

%% Client against the in-tree server (both livery_grpc) over h2c.

-define(GREETER, #{proto => helloworld_pb, service => 'Greeter', handler => greeter_server}).

client_test_() ->
    {setup, fun start/0, fun stop/1, fun(Ctx) ->
        [
            unary_ok(Ctx),
            unary_error(Ctx),
            error_details(Ctx),
            deadline_exceeded(Ctx),
            server_stream(Ctx),
            unknown_method(Ctx)
        ]
    end}.

start() ->
    {ok, _} = application:ensure_all_started(livery_grpc),
    {ok, Server} = livery_grpc:start_server(#{port => 0, services => [?GREETER]}),
    #{server => Server, port => livery_grpc:server_port(Server)}.

stop(#{server := Server}) ->
    ok = livery_grpc:stop_server(Server).

unary_ok(#{port := Port}) ->
    fun() ->
        with_conn(Port, fun(Conn) ->
            {ok, M} = livery_grpc_client:method(helloworld_pb, 'Greeter', 'SayHello'),
            ?assertEqual(
                {ok, #{message => <<"hello ada">>}},
                livery_grpc_client:call(Conn, M, #{name => <<"ada">>})
            )
        end)
    end.

unary_error(#{port := Port}) ->
    fun() ->
        with_conn(Port, fun(Conn) ->
            {ok, M} = livery_grpc_client:method(helloworld_pb, 'Greeter', 'SayHello'),
            ?assertEqual(
                {error, {invalid_argument, <<"no boom allowed">>}},
                livery_grpc_client:call(Conn, M, #{name => <<"boom">>})
            )
        end)
    end.

error_details(#{port := Port}) ->
    fun() ->
        with_conn(Port, fun(Conn) ->
            {ok, M} = livery_grpc_client:method(helloworld_pb, 'Greeter', 'SayHello'),
            ?assertEqual(
                {error, {failed_precondition, <<"needs setup">>, <<"DETAILBYTES">>}},
                livery_grpc_client:call(Conn, M, #{name => <<"details">>})
            )
        end)
    end.

deadline_exceeded(#{port := Port}) ->
    fun() ->
        with_conn(Port, fun(Conn) ->
            {ok, M} = livery_grpc_client:method(helloworld_pb, 'Greeter', 'SayHello'),
            %% The handler sleeps 2s; a 200ms deadline must abort it.
            ?assertMatch(
                {error, {deadline_exceeded, _}},
                livery_grpc_client:call(Conn, M, #{name => <<"slow">>}, #{deadline => 200})
            )
        end)
    end.

server_stream(#{port := Port}) ->
    fun() ->
        with_conn(Port, fun(Conn) ->
            {ok, M} = livery_grpc_client:method(helloworld_pb, 'Greeter', 'SayHelloStream'),
            ?assertEqual(
                {ok, [
                    #{message => <<"hi sam #1">>},
                    #{message => <<"hi sam #2">>},
                    #{message => <<"hi sam #3">>}
                ]},
                livery_grpc_client:call(Conn, M, #{name => <<"sam">>})
            )
        end)
    end.

unknown_method(#{port := Port}) ->
    fun() ->
        with_conn(Port, fun(Conn) ->
            %% A descriptor whose path the server does not know.
            M = #{
                proto => helloworld_pb,
                service => 'Greeter',
                kind => unary,
                input => 'HelloRequest',
                output => 'HelloReply',
                path => <<"/helloworld.Greeter/Nope">>
            },
            ?assertMatch(
                {error, {unimplemented, _}},
                livery_grpc_client:call(Conn, M, #{name => <<"x">>})
            )
        end)
    end.

%% Standalone (own server): gzip in both directions. The server is
%% started with gzip response compression; the client requests gzip too.
gzip_roundtrip_test() ->
    {ok, _} = application:ensure_all_started(livery_grpc),
    {ok, Server} = livery_grpc:start_server(#{
        port => 0, services => [?GREETER], compression => gzip
    }),
    Port = livery_grpc:server_port(Server),
    try
        with_conn(Port, fun(Conn) ->
            {ok, M} = livery_grpc_client:method(helloworld_pb, 'Greeter', 'SayHello'),
            ?assertEqual(
                {ok, #{message => <<"hello zoe">>}},
                livery_grpc_client:call(Conn, M, #{name => <<"zoe">>}, #{compression => gzip})
            )
        end)
    after
        livery_grpc:stop_server(Server)
    end.

%% Client interceptor stack: a `before` rewrites the request and an
%% `after_response` rewrites the reply, composed around the call.
client_interceptors_test() ->
    {ok, _} = application:ensure_all_started(livery_grpc),
    {ok, Server} = livery_grpc:start_server(#{port => 0, services => [?GREETER]}),
    Port = livery_grpc:server_port(Server),
    AddName = livery_grpc_client:before(fun(Req) ->
        livery_grpc_client:set_metadata([{<<"x-trace">>, <<"1">>}], Req#{
            message => #{name => <<"layered">>}
        })
    end),
    Tag = livery_grpc_client:after_response(fun({ok, #{message := M}}) ->
        {ok, #{message => <<M/binary, " [seen]">>}}
    end),
    try
        {ok, Conn} = livery_grpc_client:connect("localhost", Port, #{interceptors => [AddName, Tag]}),
        try
            {ok, M} = livery_grpc_client:method(helloworld_pb, 'Greeter', 'SayHello'),
            ?assertEqual(
                {ok, #{message => <<"hello layered [seen]">>}},
                livery_grpc_client:call(Conn, M, #{name => <<"ignored">>})
            )
        after
            livery_grpc_client:close(Conn)
        end
    after
        livery_grpc:stop_server(Server)
    end.

%% A livery middleware runs as a gRPC interceptor: it wraps the handler
%% and the call still succeeds.
interceptor_test() ->
    {ok, _} = application:ensure_all_started(livery_grpc),
    Counter = counters:new(1, []),
    {ok, Server} = livery_grpc:start_server(#{
        port => 0, services => [?GREETER], middleware => [{grpc_mw, Counter}]
    }),
    Port = livery_grpc:server_port(Server),
    try
        with_conn(Port, fun(Conn) ->
            {ok, M} = livery_grpc_client:method(helloworld_pb, 'Greeter', 'SayHello'),
            ?assertEqual(
                {ok, #{message => <<"hello ivy">>}},
                livery_grpc_client:call(Conn, M, #{name => <<"ivy">>})
            ),
            ?assertEqual(1, counters:get(Counter, 1))
        end)
    after
        livery_grpc:stop_server(Server)
    end.

with_conn(Port, Fun) ->
    {ok, Conn} = livery_grpc_client:connect("localhost", Port),
    try
        Fun(Conn)
    after
        livery_grpc_client:close(Conn)
    end.
