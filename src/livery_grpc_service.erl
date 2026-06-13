-module(livery_grpc_service).
-moduledoc """
Service descriptors, derived from a gpb-generated module at runtime.

A `.proto` compiled by `rebar3_gpb_plugin` yields a module (e.g.
`helloworld_pb`) that already carries introspection: `get_package_name/0`,
`get_service_names/0`, and `get_service_def/1`. Rather than generate a
second set of `*_grpc.erl` modules at build time, this module reads that
introspection and produces method descriptors the server and client use:
the wire path, the input/output message names, and the call kind (unary,
server-streaming, client-streaming, bidirectional).

A method descriptor is the unit both sides key on: the server matches an
inbound `:path` to one, the client builds a request from one.
""".

-export([service_names/1, methods/2, method/3]).
-export([kind/1, path/3, function_name/1, service_full_name/2, qualify/2, package/1]).
-export([index/1]).

-export_type([kind/0, method/0, registration/0]).

-type kind() :: unary | server_stream | client_stream | bidi.

-type method() :: #{
    name := atom(),
    %% The callback function name: the RPC name in snake_case, so the
    %% handler module reads as plain Erlang (`SayHello` -> `say_hello`).
    function := atom(),
    %% Wire path: "/package.Service/Method" (or "/Service/Method" when the
    %% proto declares no package).
    path := binary(),
    proto := module(),
    service := atom(),
    input := atom(),
    output := atom(),
    input_stream := boolean(),
    output_stream := boolean(),
    kind := kind()
}.

%% A user binding: which callback module serves a given proto service.
-type registration() :: #{
    proto := module(),
    service := atom(),
    handler := module()
}.

%%====================================================================
%% Introspection
%%====================================================================

-doc "All service names declared in a proto module.".
-spec service_names(module()) -> [atom()].
service_names(Proto) ->
    Proto:get_service_names().

-doc "The method descriptors of one service in a proto module.".
-spec methods(module(), atom()) -> [method()].
methods(Proto, Service) ->
    {{service, Service}, Rpcs} = Proto:get_service_def(Service),
    [enrich(Proto, Service, Rpc) || Rpc <- Rpcs].

-doc "One method descriptor by service and method name.".
-spec method(module(), atom(), atom()) -> {ok, method()} | error.
method(Proto, Service, MethodName) ->
    case lists:search(fun(#{name := N}) -> N =:= MethodName end, methods(Proto, Service)) of
        {value, M} -> {ok, M};
        false -> error
    end.

-spec enrich(module(), atom(), map()) -> method().
enrich(Proto, Service, Rpc) ->
    #{
        name := Name,
        input := Input,
        output := Output,
        input_stream := InStream,
        output_stream := OutStream
    } = Rpc,
    #{
        name => Name,
        function => function_name(Name),
        path => path(Proto, Service, Name),
        proto => Proto,
        service => Service,
        input => Input,
        output => Output,
        input_stream => InStream,
        output_stream => OutStream,
        kind => kind({InStream, OutStream})
    }.

%%====================================================================
%% Derived attributes
%%====================================================================

-doc "The call kind from the input/output streaming flags.".
-spec kind({boolean(), boolean()}) -> kind().
kind({false, false}) -> unary;
kind({false, true}) -> server_stream;
kind({true, false}) -> client_stream;
kind({true, true}) -> bidi.

-doc """
The wire path for a method: `/package.Service/Method`, or
`/Service/Method` when the proto declares no package.
""".
-spec path(module(), atom(), atom()) -> binary().
path(Proto, Service, MethodName) ->
    Svc = atom_to_binary(Service, utf8),
    Method = atom_to_binary(MethodName, utf8),
    case package(Proto) of
        <<>> -> <<"/", Svc/binary, "/", Method/binary>>;
        Pkg -> <<"/", Pkg/binary, ".", Svc/binary, "/", Method/binary>>
    end.

-doc """
Map an RPC method name to its callback function name: CamelCase to
snake_case (`'SayHello'` -> `say_hello`, `'HTTPGet'` -> `http_get`). A
run of capitals is kept together, with a break before the final capital
that starts the next word.
""".
-spec function_name(atom()) -> atom().
function_name(MethodName) ->
    Chars = atom_to_list(MethodName),
    binary_to_atom(iolist_to_binary(to_snake(Chars, [])), utf8).

%% Walk the CamelCase characters, inserting `_` at word boundaries:
%% lower/digit -> upper, and the last upper in a run before a lower.
-spec to_snake(string(), string()) -> [string() | byte()].
to_snake([], _Prev) ->
    [];
to_snake([C | Rest], Prev) when C >= $A, C =< $Z ->
    Lower = C + 32,
    NeedsSep =
        case {Prev, Rest} of
            {[], _} -> false;
            {[P | _], _} when P >= $a, P =< $z -> true;
            {[P | _], _} when P >= $0, P =< $9 -> true;
            {[P | _], [N | _]} when P >= $A, P =< $Z, N >= $a, N =< $z -> true;
            _ -> false
        end,
    case NeedsSep of
        true -> [$_, Lower | to_snake(Rest, [C | Prev])];
        false -> [Lower | to_snake(Rest, [C | Prev])]
    end;
to_snake([C | Rest], _Prev) ->
    [C | to_snake(Rest, [C])].

-doc "The fully qualified service name, e.g. `<<\"helloworld.Greeter\">>`.".
-spec service_full_name(module(), atom()) -> binary().
service_full_name(Proto, Service) ->
    qualify(package(Proto), atom_to_binary(Service, utf8)).

-doc "Join a package and a local name into a fully qualified name.".
-spec qualify(binary(), binary()) -> binary().
qualify(<<>>, Name) -> Name;
qualify(Package, Name) -> <<Package/binary, ".", Name/binary>>.

-doc "The proto package as a binary, or `<<>>` when none is declared.".
-spec package(module()) -> binary().
package(Proto) ->
    case erlang:function_exported(Proto, get_package_name, 0) of
        true -> normalize_package(Proto:get_package_name());
        false -> <<>>
    end.

-spec normalize_package(atom() | undefined) -> binary().
normalize_package(undefined) -> <<>>;
normalize_package('') -> <<>>;
normalize_package(Pkg) when is_atom(Pkg) -> atom_to_binary(Pkg, utf8).

%%====================================================================
%% Routing index
%%====================================================================

-doc """
Build a path-keyed routing index from a list of registrations.

Each entry maps a wire path to `{Method, Handler}`: the method descriptor
plus the callback module that serves it. The server uses this to dispatch
an inbound request in one map lookup.
""".
-spec index([registration()]) -> #{binary() => {method(), module()}}.
index(Registrations) ->
    lists:foldl(fun index_one/2, #{}, Registrations).

-spec index_one(registration(), map()) -> map().
index_one(#{proto := Proto, service := Service, handler := Handler}, Acc) ->
    lists:foldl(
        fun(#{path := Path} = M, A) -> A#{Path => {M, Handler}} end,
        Acc,
        methods(Proto, Service)
    ).
