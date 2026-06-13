-module(livery_grpc_reflection_tests).

-include_lib("eunit/include/eunit.hrl").

%% Drive the bidirectional reflection RPC with the in-tree client.

-define(GREETER, #{proto => helloworld_pb, service => 'Greeter', handler => greeter_server}).

reflection_test_() ->
    {setup, fun start/0, fun stop/1, fun(Ctx) ->
        [
            list_services(Ctx),
            file_containing_symbol(Ctx),
            unknown_symbol(Ctx)
        ]
    end}.

start() ->
    {ok, _} = application:ensure_all_started(livery_grpc),
    {ok, Server} = livery_grpc:start_server(#{
        port => 0, reflection => true, services => [?GREETER]
    }),
    #{server => Server, port => livery_grpc:server_port(Server)}.

stop(#{server := Server}) ->
    ok = livery_grpc:stop_server(Server).

list_services(#{port := Port}) ->
    fun() ->
        #{message_response := {list_services_response, #{service := Services}}} =
            reflect(Port, {list_services, <<>>}),
        Names = [N || #{name := N} <- Services],
        ?assert(lists:member(<<"helloworld.Greeter">>, Names)),
        ?assert(lists:member(<<"grpc.reflection.v1.ServerReflection">>, Names))
    end.

file_containing_symbol(#{port := Port}) ->
    fun() ->
        #{message_response := {file_descriptor_response, #{file_descriptor_proto := Files}}} =
            reflect(Port, {file_containing_symbol, <<"helloworld.Greeter">>}),
        ?assert(length(Files) >= 1),
        ?assert(lists:all(fun is_binary/1, Files))
    end.

unknown_symbol(#{port := Port}) ->
    fun() ->
        #{message_response := {error_response, #{error_code := Code}}} =
            reflect(Port, {file_containing_symbol, <<"nope.Nothing">>}),
        ?assertEqual(5, Code)
    end.

%% Open the reflection stream, send one request, return the one response.
reflect(Port, MessageRequest) ->
    {ok, Conn} = livery_grpc_client:connect("localhost", Port),
    try
        {ok, M} = livery_grpc_client:method(
            reflection_pb, 'ServerReflection', 'ServerReflectionInfo'
        ),
        {ok, Call} = livery_grpc_client:open(Conn, M),
        ok = livery_grpc_client:send(Call, #{message_request => MessageRequest}),
        {ok, Response, _} = livery_grpc_client:recv(Call),
        ok = livery_grpc_client:send_end(Call),
        Response
    after
        livery_grpc_client:close(Conn)
    end.
