-module(livery_grpc_e2e_SUITE).
-moduledoc """
End-to-end suite against a real running server.

Boots one livery_grpc server (Greeter + health + reflection) on a real
h2c port, then exercises the full journey two ways: with the in-tree
client (`local` group) and with grpcurl, a real grpc-go client, over
reflection so no `.proto` is needed (`grpcurl` group, skipped if grpcurl
is not installed).
""".

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

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
            t_reflection_list
        ]},
        {grpcurl, [], [
            t_grpcurl_list,
            t_grpcurl_unary,
            t_grpcurl_client_stream,
            t_grpcurl_bidi,
            t_grpcurl_health
        ]}
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(livery_grpc),
    {ok, Server} = livery_grpc:start_server(#{
        port => 0, reflection => true, services => [?GREETER, livery_grpc_health:service()]
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

%%====================================================================
%% Helpers
%%====================================================================

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
