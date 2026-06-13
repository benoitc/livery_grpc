-module(livery_grpc_codegen_tests).

-include_lib("eunit/include/eunit.hrl").

%% Generate the greeter stubs, compile them, and exercise the generated
%% client against a live server, plus check the generated behaviour.

-define(GREETER, #{proto => helloworld_pb, service => 'Greeter', handler => greeter_server}).

codegen_test_() ->
    {setup, fun start/0, fun stop/1, fun(Ctx) ->
        [
            generated_client_calls(Ctx),
            generated_behaviour_callbacks(Ctx)
        ]
    end}.

start() ->
    {ok, _} = application:ensure_all_started(livery_grpc),
    OutDir = filename:join(["/tmp", "livery_grpc_codegen_test"]),
    {ok, Paths} = livery_grpc_codegen:generate(helloworld_pb, OutDir),
    [load_module(P) || P <- Paths],
    {ok, Server} = livery_grpc:start_server(#{port => 0, services => [?GREETER]}),
    #{server => Server, port => livery_grpc:server_port(Server)}.

stop(#{server := Server}) ->
    ok = livery_grpc:stop_server(Server).

%% The generated greeter_client covers all four call shapes.
generated_client_calls(#{port := Port}) ->
    fun() ->
        {ok, Conn} = livery_grpc_client:connect("localhost", Port),
        try
            ?assertEqual(
                {ok, #{message => <<"hello gen">>}},
                greeter_client:say_hello(Conn, #{name => <<"gen">>})
            ),
            ?assertMatch(
                {ok, [#{message := _}, #{message := _}, #{message := _}]},
                greeter_client:say_hello_stream(Conn, #{name => <<"s">>})
            ),
            ?assertEqual(
                {ok, #{message => <<"hello a, b">>}},
                greeter_client:say_hello_collect(Conn, [#{name => <<"a">>}, #{name => <<"b">>}])
            ),
            {ok, Call} = greeter_client:say_hello_chat(Conn),
            ok = livery_grpc_client:send(Call, #{name => <<"ping">>}),
            ?assertMatch({ok, #{message := <<"hi ping">>}, _}, livery_grpc_client:recv(Call))
        after
            livery_grpc_client:close(Conn)
        end
    end.

generated_behaviour_callbacks(_Ctx) ->
    fun() ->
        Callbacks = lists:sort(greeter_service:behaviour_info(callbacks)),
        ?assertEqual(
            lists:sort([
                {say_hello, 2},
                {say_hello_stream, 3},
                {say_hello_collect, 2},
                {say_hello_chat, 2}
            ]),
            Callbacks
        )
    end.

load_module(Path) ->
    {ok, Module, Bin} = compile:file(Path, [binary, return_errors, debug_info]),
    {module, Module} = code:load_binary(Module, Path, Bin),
    Module.
