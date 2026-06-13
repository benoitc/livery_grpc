-module(livery_grpc_service_tests).

-include_lib("eunit/include/eunit.hrl").

service_names_test() ->
    ?assertEqual(['Greeter'], livery_grpc_service:service_names(helloworld_pb)).

methods_cover_all_kinds_test() ->
    Ms = livery_grpc_service:methods(helloworld_pb, 'Greeter'),
    Kinds = [maps:get(kind, M) || M <- Ms],
    ?assertEqual([unary, server_stream, client_stream, bidi], Kinds).

method_descriptor_test() ->
    {ok, M} = livery_grpc_service:method(helloworld_pb, 'Greeter', 'SayHello'),
    ?assertEqual(<<"/helloworld.Greeter/SayHello">>, maps:get(path, M)),
    ?assertEqual(say_hello, maps:get(function, M)),
    ?assertEqual('HelloRequest', maps:get(input, M)),
    ?assertEqual('HelloReply', maps:get(output, M)),
    ?assertEqual(unary, maps:get(kind, M)).

method_missing_test() ->
    ?assertEqual(error, livery_grpc_service:method(helloworld_pb, 'Greeter', 'Nope')).

function_name_test() ->
    ?assertEqual(say_hello, livery_grpc_service:function_name('SayHello')),
    ?assertEqual(say_hello_stream, livery_grpc_service:function_name('SayHelloStream')),
    ?assertEqual(http_get, livery_grpc_service:function_name('HTTPGet')),
    ?assertEqual(get, livery_grpc_service:function_name('Get')).

kind_mapping_test() ->
    ?assertEqual(unary, livery_grpc_service:kind({false, false})),
    ?assertEqual(server_stream, livery_grpc_service:kind({false, true})),
    ?assertEqual(client_stream, livery_grpc_service:kind({true, false})),
    ?assertEqual(bidi, livery_grpc_service:kind({true, true})).

index_test() ->
    Reg = #{proto => helloworld_pb, service => 'Greeter', handler => my_handler},
    Index = livery_grpc_service:index([Reg]),
    ?assertEqual(4, map_size(Index)),
    {M, Handler} = maps:get(<<"/helloworld.Greeter/SayHello">>, Index),
    ?assertEqual(my_handler, Handler),
    ?assertEqual(say_hello, maps:get(function, M)).
