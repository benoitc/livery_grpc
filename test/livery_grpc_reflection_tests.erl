-module(livery_grpc_reflection_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("gpb/descr_src/gpb_descriptor.hrl").

%% Drive the bidirectional reflection RPC with the in-tree client.

-define(GREETER, #{proto => helloworld_pb, service => 'Greeter', handler => greeter_server}).

reflection_test_() ->
    {setup, fun start/0, fun stop/1, fun(Ctx) ->
        [
            list_services(Ctx),
            file_containing_symbol(Ctx),
            unknown_symbol(Ctx),
            map_symbol(Ctx)
        ]
    end}.

start() ->
    {ok, _} = application:ensure_all_started(livery_grpc),
    {ok, Server} = livery_grpc:start_server(#{
        port => 0, reflection => true, services => [?GREETER, map_fixture:registration()]
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

%% The descriptors reach a client with the map entries nested.
map_symbol(#{port := Port}) ->
    fun() ->
        #{message_response := {file_descriptor_response, #{file_descriptor_proto := Bins}}} =
            reflect(Port, {file_containing_symbol, <<"livery.interop.v1.MapEcho">>}),
        Request = message(decode_files(Bins), "livery/interop/v1/mapfields.proto", "MapRequest"),
        ?assertEqual(
            ["ByNameEntry", "ExtraLabelsEntry", "LabelsEntry", "Nested"],
            nested_names(Request)
        )
    end.

%%====================================================================
%% Map entry normalisation (no server)
%%====================================================================

map_entries_test_() ->
    Files = served_files(),
    Request = message(Files, "livery/interop/v1/mapfields.proto", "MapRequest"),
    Struct = message(Files, "google/protobuf/struct.proto", "Struct"),
    [
        {"no top-level map entry is left", fun() ->
            ?assertEqual([], [
                M#'DescriptorProto'.name
             || #'FileDescriptorProto'{message_type = Msgs} <- Files,
                M <- Msgs,
                is_entry(M)
            ])
        end},
        {"each map field has its own nested entry", fun() ->
            ?assertEqual(
                ["ByNameEntry", "ExtraLabelsEntry", "LabelsEntry", "Nested"],
                nested_names(Request)
            ),
            ?assertEqual(".livery.interop.v1.MapRequest.LabelsEntry", type_name(Request, "labels")),
            ?assertEqual(
                ".livery.interop.v1.MapRequest.ExtraLabelsEntry",
                type_name(Request, "extra_labels")
            ),
            ?assertEqual(".livery.interop.v1.MapRequest.ByNameEntry", type_name(Request, "by_name"))
        end},
        {"a map in a nested message is nested there", fun() ->
            Nested = nested(Request, "Nested"),
            ?assertEqual(["ByIdEntry"], nested_names(Nested)),
            ?assertEqual(
                ".livery.interop.v1.MapRequest.Nested.ByIdEntry", type_name(Nested, "by_id")
            )
        end},
        {"imported files are rewritten too", fun() ->
            ?assertEqual(["FieldsEntry"], nested_names(Struct)),
            ?assertEqual(".google.protobuf.Struct.FieldsEntry", type_name(Struct, "fields"))
        end},
        {"entries are map_entry with optional key and value", fun() ->
            Entry = nested(Request, "ByNameEntry"),
            ?assert(is_entry(Entry)),
            ?assertEqual(
                [{"key", 1, 'LABEL_OPTIONAL'}, {"value", 2, 'LABEL_OPTIONAL'}],
                [
                    {N, Num, L}
                 || #'FieldDescriptorProto'{name = N, number = Num, label = L} <-
                        Entry#'DescriptorProto'.field
                ]
            ),
            ?assertEqual(".livery.interop.v1.Inner", type_name(Entry, "value"))
        end},
        {"nested and imported symbols resolve", fun() ->
            #{symbols := Symbols} = livery_grpc_reflection:build([map_fixture:registration()]),
            [
                ?assert(maps:is_key(Symbol, Symbols))
             || Symbol <- [
                    <<"livery.interop.v1.MapEcho">>,
                    <<"livery.interop.v1.MapEcho.Echo">>,
                    <<"livery.interop.v1.MapRequest.Nested">>,
                    <<"livery.interop.v1.MapRequest.LabelsEntry">>,
                    <<"google.protobuf.Struct">>,
                    <<"google.protobuf.NullValue">>
                ]
            ]
        end},
        {"a proto without maps is unchanged", fun() ->
            #{files := #{<<"helloworld/helloworld.proto">> := Bins}} =
                livery_grpc_reflection:build([?GREETER]),
            #'FileDescriptorSet'{file = Original} =
                gpb_descriptor:decode_msg(helloworld_pb:descriptor(), 'FileDescriptorSet'),
            ?assertEqual(Original, decode_files(Bins))
        end}
    ].

served_files() ->
    #{symbols := #{<<"livery.interop.v1.MapEcho">> := Bins}} =
        livery_grpc_reflection:build([map_fixture:registration()]),
    decode_files(Bins).

decode_files(Bins) ->
    [gpb_descriptor:decode_msg(B, 'FileDescriptorProto') || B <- Bins].

message(Files, FileName, MsgName) ->
    [Msg] = [
        M
     || #'FileDescriptorProto'{name = N, message_type = Msgs} <- Files,
        N =:= FileName,
        #'DescriptorProto'{name = MN} = M <- Msgs,
        MN =:= MsgName
    ],
    Msg.

nested(#'DescriptorProto'{nested_type = Nested}, Name) ->
    [Msg] = [M || #'DescriptorProto'{name = N} = M <- Nested, N =:= Name],
    Msg.

nested_names(#'DescriptorProto'{nested_type = Nested}) ->
    lists:sort([N || #'DescriptorProto'{name = N} <- Nested]).

type_name(#'DescriptorProto'{field = Fields}, FieldName) ->
    [TypeName] = [
        T
     || #'FieldDescriptorProto'{name = N, type_name = T} <- Fields, N =:= FieldName
    ],
    TypeName.

is_entry(#'DescriptorProto'{options = #'MessageOptions'{map_entry = true}}) -> true;
is_entry(_) -> false.

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
