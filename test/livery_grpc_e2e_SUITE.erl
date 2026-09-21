-module(livery_grpc_e2e_SUITE).
-moduledoc """
End-to-end suite against a real running server.

Boots one livery_grpc server (Greeter + MapEcho + health + reflection) on a real
h2c port, then exercises the full journey two ways: with the in-tree
client (`local` group) and with grpcurl, a real grpc-go client, over
reflection so no `.proto` is needed (`grpcurl` group, skipped if grpcurl
is not installed).
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("gpb/descr_src/gpb_descriptor.hrl").

-define(GREETER, #{proto => helloworld_pb, service => 'Greeter', handler => greeter_server}).

%%====================================================================
%% CT callbacks
%%====================================================================

all() ->
    [{group, local}, {group, grpcurl}].

groups() ->
    [
        {local, [parallel], [
            t_unary,
            t_unary_error,
            t_server_stream,
            t_client_stream,
            t_bidi,
            t_deadline,
            t_health_check,
            t_health_watch,
            t_reflection_list,
            t_map_unary,
            t_map_reflection
        ]},
        {grpcurl, [], [
            t_grpcurl_list,
            t_grpcurl_unary,
            t_grpcurl_client_stream,
            t_grpcurl_bidi,
            t_grpcurl_health,
            t_grpcurl_describe_map,
            t_grpcurl_map_call
        ]}
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(livery_grpc),
    {ok, Server} = livery_grpc:start_server(#{
        port => 0,
        reflection => true,
        services => [?GREETER, map_fixture:registration(), livery_grpc_health:service()]
    }),
    [{server, Server}, {port, livery_grpc:server_port(Server)} | Config].

end_per_suite(Config) ->
    ok = livery_grpc:stop_server(?config(server, Config)),
    Config.

init_per_group(grpcurl, Config) ->
    case os:find_executable("grpcurl") of
        false -> {skip, "grpcurl not installed"};
        Path -> [{grpcurl, Path} | Config]
    end;
init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

%%====================================================================
%% In-tree client journey
%%====================================================================

t_unary(Config) ->
    with_conn(Config, fun(Conn) ->
        M = method('SayHello'),
        ?assertEqual(
            {ok, #{message => <<"hello e2e">>}},
            livery_grpc_client:call(Conn, M, #{name => <<"e2e">>})
        )
    end).

t_unary_error(Config) ->
    with_conn(Config, fun(Conn) ->
        ?assertEqual(
            {error, {invalid_argument, <<"no boom allowed">>}},
            livery_grpc_client:call(Conn, method('SayHello'), #{name => <<"boom">>})
        )
    end).

t_server_stream(Config) ->
    with_conn(Config, fun(Conn) ->
        {ok, Replies} = livery_grpc_client:call(Conn, method('SayHelloStream'), #{name => <<"s">>}),
        ?assertEqual(3, length(Replies))
    end).

t_client_stream(Config) ->
    with_conn(Config, fun(Conn) ->
        ?assertEqual(
            {ok, #{message => <<"hello a, b, c">>}},
            livery_grpc_client:client_stream(Conn, method('SayHelloCollect'), [
                #{name => <<"a">>}, #{name => <<"b">>}, #{name => <<"c">>}
            ])
        )
    end).

t_bidi(Config) ->
    with_conn(Config, fun(Conn) ->
        {ok, Call} = livery_grpc_client:open(Conn, method('SayHelloChat')),
        ok = livery_grpc_client:send(Call, #{name => <<"a">>}),
        {ok, #{message := <<"hi a">>}, Call1} = livery_grpc_client:recv(Call),
        ok = livery_grpc_client:send(Call1, #{name => <<"b">>}),
        {ok, #{message := <<"hi b">>}, _} = livery_grpc_client:recv(Call1)
    end).

t_deadline(Config) ->
    with_conn(Config, fun(Conn) ->
        ?assertMatch(
            {error, {deadline_exceeded, _}},
            livery_grpc_client:call(Conn, method('SayHello'), #{name => <<"slow">>}, #{
                deadline => 200
            })
        )
    end).

t_health_check(Config) ->
    with_conn(Config, fun(Conn) ->
        {ok, HC} = livery_grpc_client:method(health_pb, 'Health', 'Check'),
        ?assertEqual(
            {ok, #{status => 'SERVING'}},
            livery_grpc_client:call(Conn, HC, #{service => <<>>})
        )
    end).

t_health_watch(Config) ->
    Service = <<"watch.e2e">>,
    ok = livery_grpc_health:set_serving(Service),
    with_conn(Config, fun(Conn) ->
        {ok, W} = livery_grpc_client:method(health_pb, 'Health', 'Watch'),
        {ok, Call} = livery_grpc_client:open(Conn, W),
        ok = livery_grpc_client:send(Call, #{service => Service}),
        ok = livery_grpc_client:send_end(Call),
        {ok, #{status := 'SERVING'}, Call1} = livery_grpc_client:recv(Call),
        ok = livery_grpc_health:set_not_serving(Service),
        ?assertMatch({ok, #{status := 'NOT_SERVING'}, _}, livery_grpc_client:recv(Call1))
    end).

t_reflection_list(Config) ->
    with_conn(Config, fun(Conn) ->
        {ok, R} = livery_grpc_client:method(
            reflection_pb, 'ServerReflection', 'ServerReflectionInfo'
        ),
        {ok, Call} = livery_grpc_client:open(Conn, R),
        ok = livery_grpc_client:send(Call, #{message_request => {list_services, <<>>}}),
        {ok, #{message_response := {list_services_response, #{service := Services}}}, _} =
            livery_grpc_client:recv(Call),
        Names = [N || #{name := N} <- Services],
        ?assert(lists:member(<<"helloworld.Greeter">>, Names))
    end).

%% Map and Struct fields round-trip through the in-tree client.
t_map_unary(Config) ->
    with_conn(Config, fun(Conn) ->
        {ok, M} = livery_grpc_client:method(mapfields_pb, 'MapEcho', 'Echo'),
        Request = #{
            labels => #{<<"env">> => <<"prod">>, <<"tier">> => <<"web">>},
            extra_labels => #{<<"zone">> => <<"a">>},
            by_name => #{<<"one">> => #{note => <<"first">>}},
            meta => #{
                fields => #{
                    <<"name">> => #{kind => {string_value, <<"e2e">>}},
                    <<"count">> => #{kind => {number_value, 2.0}}
                }
            },
            nested => #{by_id => #{7 => #{note => <<"seven">>}}}
        },
        ?assertEqual({ok, Request}, livery_grpc_client:call(Conn, M, Request))
    end).

%% The in-tree client reads the map schema over reflection: every map field
%% points at an entry nested in its owner, across the file and its imports.
t_map_reflection(Config) ->
    with_conn(Config, fun(Conn) ->
        {ok, R} = livery_grpc_client:method(
            reflection_pb, 'ServerReflection', 'ServerReflectionInfo'
        ),
        {ok, Call} = livery_grpc_client:open(Conn, R),
        ok = livery_grpc_client:send(Call, #{
            message_request => {file_containing_symbol, <<"livery.interop.v1.MapRequest">>}
        }),
        {ok, #{message_response := {file_descriptor_response, #{file_descriptor_proto := Bins}}},
            _} = livery_grpc_client:recv(Call),
        ok = livery_grpc_client:send_end(Call),
        Files = [gpb_descriptor:decode_msg(B, 'FileDescriptorProto') || B <- Bins],
        Entries = lists:sort(lists:flatmap(fun map_entries/1, Files)),
        ?assertEqual(
            [
                ".google.protobuf.Struct.FieldsEntry",
                ".livery.interop.v1.MapRequest.ByNameEntry",
                ".livery.interop.v1.MapRequest.ExtraLabelsEntry",
                ".livery.interop.v1.MapRequest.LabelsEntry",
                ".livery.interop.v1.MapRequest.Nested.ByIdEntry"
            ],
            Entries
        ),
        ?assertEqual([], Entries -- lists:flatmap(fun repeated_msg_types/1, Files))
    end).

%%====================================================================
%% grpcurl (real external grpc-go client, over reflection)
%%====================================================================

t_grpcurl_list(Config) ->
    Out = grpcurl(Config, "", "list"),
    ?assert(contains(Out, "helloworld.Greeter")),
    ?assert(contains(Out, "grpc.health.v1.Health")).

t_grpcurl_unary(Config) ->
    Out = grpcurl(Config, "-d '{\"name\":\"grpcurl\"}'", "helloworld.Greeter/SayHello"),
    ?assert(contains(Out, "hello grpcurl")).

t_grpcurl_client_stream(Config) ->
    Out = grpcurl_piped(
        Config, "{\"name\":\"a\"}\\n{\"name\":\"b\"}\\n", "helloworld.Greeter/SayHelloCollect"
    ),
    ?assert(contains(Out, "hello a, b")).

t_grpcurl_bidi(Config) ->
    Out = grpcurl_piped(
        Config, "{\"name\":\"x\"}\\n{\"name\":\"y\"}\\n", "helloworld.Greeter/SayHelloChat"
    ),
    ?assert(contains(Out, "hi x")),
    ?assert(contains(Out, "hi y")).

t_grpcurl_health(Config) ->
    Out = grpcurl(Config, "-d '{\"service\":\"\"}'", "grpc.health.v1.Health/Check"),
    ?assert(contains(Out, "SERVING")).

%% protoreflect accepts the served descriptors and renders the map fields.
t_grpcurl_describe_map(Config) ->
    Request = grpcurl(Config, "", "describe livery.interop.v1.MapRequest"),
    ?assert(contains(Request, "map<string, string> labels")),
    ?assert(contains(Request, "map<string, string> extra_labels")),
    ?assert(contains(Request, "map<string, .livery.interop.v1.Inner> by_name")),
    ?assert(contains(Request, "map<int32, .livery.interop.v1.Inner> by_id")),
    Struct = grpcurl(Config, "", "describe google.protobuf.Struct"),
    ?assert(contains(Struct, "map<string, .google.protobuf.Value> fields")).

t_grpcurl_map_call(Config) ->
    Out = grpcurl(
        Config,
        "-d '{\"labels\":{\"env\":\"prod\"},\"by_name\":{\"one\":{\"note\":\"first\"}},"
        "\"meta\":{\"name\":\"grpcurl\"},\"nested\":{\"by_id\":{\"7\":{\"note\":\"seven\"}}}}'",
        "livery.interop.v1.MapEcho/Echo"
    ),
    ?assert(contains(Out, "\"env\": \"prod\"")),
    ?assert(contains(Out, "\"note\": \"first\"")),
    ?assert(contains(Out, "\"name\": \"grpcurl\"")),
    ?assert(contains(Out, "\"note\": \"seven\"")).

%%====================================================================
%% Helpers
%%====================================================================

%% Fully qualified names of the map entry messages defined in a file.
map_entries(#'FileDescriptorProto'{package = Package, message_type = Msgs}) ->
    lists:flatmap(fun(M) -> map_entries("." ++ Package, M) end, Msgs).

map_entries(Scope, #'DescriptorProto'{name = Name, nested_type = Nested, options = Options}) ->
    Fqn = Scope ++ "." ++ Name,
    Own =
        case Options of
            #'MessageOptions'{map_entry = true} -> [Fqn];
            _ -> []
        end,
    Own ++ lists:flatmap(fun(M) -> map_entries(Fqn, M) end, Nested).

%% The type names the repeated message fields of a file point at: every
%% map field is one of them.
repeated_msg_types(#'FileDescriptorProto'{message_type = Msgs}) ->
    lists:flatmap(fun repeated_msg_types/1, Msgs);
repeated_msg_types(#'DescriptorProto'{options = #'MessageOptions'{map_entry = true}}) ->
    [];
repeated_msg_types(#'DescriptorProto'{field = Fields, nested_type = Nested}) ->
    [
        T
     || #'FieldDescriptorProto'{label = 'LABEL_REPEATED', type = 'TYPE_MESSAGE', type_name = T} <-
            Fields
    ] ++ lists:flatmap(fun repeated_msg_types/1, Nested).

method(Name) ->
    {ok, M} = livery_grpc_client:method(helloworld_pb, 'Greeter', Name),
    M.

with_conn(Config, Fun) ->
    {ok, Conn} = livery_grpc_client:connect("localhost", ?config(port, Config)),
    try
        Fun(Conn)
    after
        livery_grpc_client:close(Conn)
    end.

%% Run grpcurl over reflection (no -proto): grpcurl -plaintext FLAGS
%% localhost:PORT SYMBOL.
grpcurl(Config, Flags, Symbol) ->
    os:cmd(grpcurl_cmd(Config, Flags, Symbol)).

%% Stream newline-delimited JSON into grpcurl's `-d @` for client-streaming
%% and bidirectional calls.
grpcurl_piped(Config, Input, Symbol) ->
    Cmd = lists:flatten(["printf '", Input, "' | ", grpcurl_cmd(Config, "-d @", Symbol)]),
    os:cmd(Cmd).

grpcurl_cmd(Config, Flags, Symbol) ->
    Port = integer_to_list(?config(port, Config)),
    lists:flatten(["grpcurl -plaintext ", Flags, " localhost:", Port, " ", Symbol]).

contains(Haystack, Needle) ->
    string:find(Haystack, Needle) =/= nomatch.
