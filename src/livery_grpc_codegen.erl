-module(livery_grpc_codegen).
-moduledoc """
Generate Erlang stubs from a compiled gpb proto module.

Two kinds of module, per service, so a service reads as plain Erlang:

- A client stub `<service>_client`, giving an `erpc`-style call per RPC:
  `greeter_client:say_hello(Conn, Request)`. Unary and server-streaming
  wrap `livery_grpc_client:call/4`, client-streaming wraps
  `client_stream/4`, and bidirectional wraps `open/3` (returning a stream
  handle to drive with `send/2`, `recv/1`, ...).

- A behaviour `<service>_service`, declaring one `-callback` per RPC so a
  handler module can `-behaviour(greeter_service)` and have the compiler
  and dialyzer check it.

`generate/2,3` writes the source to a directory; `client_module/2` and
`behaviour_module/2` return `{Module, Source}` for callers that compile in
memory. The generated client resolves the method descriptor at call time
via `livery_grpc_service`, so it stays correct if the proto is recompiled.
""".

-export([client_module/2, behaviour_module/2, generate/2, generate/3]).

-export_type([kind/0]).

-type kind() :: client | behaviour.

%%====================================================================
%% File generation
%%====================================================================

-doc "`generate/3` writing both the client and behaviour modules.".
-spec generate(module(), file:name_all()) -> {ok, [file:name_all()]} | {error, term()}.
generate(Proto, OutDir) ->
    generate(Proto, OutDir, [client, behaviour]).

-doc """
Write the chosen stub kinds for every service in `Proto` to `OutDir`.
Returns the list of written file paths.
""".
-spec generate(module(), file:name_all(), [kind()]) ->
    {ok, [file:name_all()]} | {error, term()}.
generate(Proto, OutDir, Kinds) ->
    ok = filelib:ensure_dir(filename:join(OutDir, "x")),
    Modules = [
        Pair
     || Service <- Proto:get_service_names(),
        Kind <- Kinds,
        Pair <- [render(Kind, Proto, Service)]
    ],
    write_all(Modules, OutDir, []).

-spec write_all([{module(), iolist()}], file:name_all(), [file:name_all()]) ->
    {ok, [file:name_all()]} | {error, term()}.
write_all([], _OutDir, Acc) ->
    {ok, lists:reverse(Acc)};
write_all([{Module, Source} | Rest], OutDir, Acc) ->
    Path = filename:join(OutDir, atom_to_list(Module) ++ ".erl"),
    case file:write_file(Path, Source) of
        ok -> write_all(Rest, OutDir, [Path | Acc]);
        {error, _} = E -> E
    end.

-spec render(kind(), module(), atom()) -> {module(), iolist()}.
render(client, Proto, Service) -> client_module(Proto, Service);
render(behaviour, Proto, Service) -> behaviour_module(Proto, Service).

%%====================================================================
%% Client stub
%%====================================================================

-doc "Return `{Module, Source}` for a service's client stub module.".
-spec client_module(module(), atom()) -> {module(), iolist()}.
client_module(Proto, Service) ->
    Module = module_name(Service, "_client"),
    Methods = livery_grpc_service:methods(Proto, Service),
    Exports = lists:flatmap(fun client_exports/1, Methods),
    Source = [
        header(Module, ["Generated gRPC client for ", full_name(Proto, Service), ". Do not edit."]),
        export_attr(Exports ++ [{method, 1}]),
        [client_fun(M) || M <- Methods],
        method_helper(Proto, Service)
    ],
    {Module, Source}.

-spec client_exports(livery_grpc_service:method()) -> [{atom(), arity()}].
client_exports(#{function := Fn, kind := bidi}) -> [{Fn, 1}, {Fn, 2}];
client_exports(#{function := Fn}) -> [{Fn, 2}, {Fn, 3}].

-spec client_fun(livery_grpc_service:method()) -> iolist().
client_fun(#{function := Fn, name := Name, kind := Kind}) when
    Kind =:= unary; Kind =:= server_stream
->
    F = atom_to_list(Fn),
    [
        fmt("~s(Conn, Request) -> ~s(Conn, Request, #{}).\n", [F, F]),
        fmt(
            "~s(Conn, Request, Opts) ->\n"
            "    livery_grpc_client:call(Conn, method(~p), Request, Opts).\n\n",
            [F, Name]
        )
    ];
client_fun(#{function := Fn, name := Name, kind := client_stream}) ->
    F = atom_to_list(Fn),
    [
        fmt("~s(Conn, Requests) -> ~s(Conn, Requests, #{}).\n", [F, F]),
        fmt(
            "~s(Conn, Requests, Opts) ->\n"
            "    livery_grpc_client:client_stream(Conn, method(~p), Requests, Opts).\n\n",
            [F, Name]
        )
    ];
client_fun(#{function := Fn, name := Name, kind := bidi}) ->
    F = atom_to_list(Fn),
    [
        fmt("~s(Conn) -> ~s(Conn, #{}).\n", [F, F]),
        fmt(
            "~s(Conn, Opts) ->\n"
            "    livery_grpc_client:open(Conn, method(~p), Opts).\n\n",
            [F, Name]
        )
    ].

-spec method_helper(module(), atom()) -> iolist().
method_helper(Proto, Service) ->
    fmt(
        "method(Name) ->\n"
        "    {ok, Descriptor} = livery_grpc_service:method(~p, ~p, Name),\n"
        "    Descriptor.\n",
        [Proto, Service]
    ).

%%====================================================================
%% Service behaviour
%%====================================================================

-doc "Return `{Module, Source}` for a service's callback behaviour module.".
-spec behaviour_module(module(), atom()) -> {module(), iolist()}.
behaviour_module(Proto, Service) ->
    Module = module_name(Service, "_service"),
    Methods = livery_grpc_service:methods(Proto, Service),
    Source = [
        header(Module, [
            "gRPC service behaviour for ",
            full_name(Proto, Service),
            ". Implement these callbacks. Do not edit."
        ]),
        [callback(M) || M <- Methods]
    ],
    {Module, Source}.

-spec callback(livery_grpc_service:method()) -> iolist().
callback(#{function := Fn, kind := unary}) ->
    fmt(
        "-callback ~s(Request :: map(), Ctx :: livery_grpc_server:ctx()) ->\n"
        "    livery_grpc_server:callback_result().\n\n",
        [Fn]
    );
callback(#{function := Fn, kind := server_stream}) ->
    fmt(
        "-callback ~s(Request :: map(),\n"
        "             Send :: fun((map()) -> ok | {error, term()}),\n"
        "             Ctx :: livery_grpc_server:ctx()) -> ok | {error, term()}.\n\n",
        [Fn]
    );
callback(#{function := Fn, kind := client_stream}) ->
    fmt(
        "-callback ~s(Stream :: livery_grpc_stream:stream(),\n"
        "             Ctx :: livery_grpc_server:ctx()) ->\n"
        "    livery_grpc_server:callback_result().\n\n",
        [Fn]
    );
callback(#{function := Fn, kind := bidi}) ->
    fmt(
        "-callback ~s(Stream :: livery_grpc_stream:stream(),\n"
        "             Ctx :: livery_grpc_server:ctx()) -> ok | {error, term()}.\n\n",
        [Fn]
    ).

%%====================================================================
%% Shared rendering
%%====================================================================

-spec header(module(), iolist()) -> iolist().
header(Module, Doc) ->
    [
        fmt("-module(~s).\n", [Module]),
        fmt("-moduledoc \"~s\".\n\n", [iolist_to_binary(Doc)])
    ].

-spec export_attr([{atom(), arity()}]) -> iolist().
export_attr(Funs) ->
    Entries = [fmt("~s/~B", [F, A]) || {F, A} <- Funs],
    fmt("-export([~s]).\n\n", [lists:join(", ", Entries)]).

-spec module_name(atom(), string()) -> module().
module_name(Service, Suffix) ->
    Base = atom_to_list(livery_grpc_service:function_name(Service)),
    list_to_atom(Base ++ Suffix).

-spec full_name(module(), atom()) -> binary().
full_name(Proto, Service) ->
    livery_grpc_service:service_full_name(Proto, Service).

-spec fmt(io:format(), [term()]) -> iolist().
fmt(Format, Args) ->
    io_lib:format(Format, Args).
