-module(livery_grpc_reflection).
-moduledoc """
The v1 gRPC server reflection service (`grpc.reflection.v1`).

Lets tools like grpcurl and Postman discover services and message schemas
at runtime, without a local `.proto`. Enable it by starting the server
with `reflection => true` (see `livery_grpc:start_server/1`), which mounts
this service and feeds it the descriptor set built from every registered
service.

`ServerReflectionInfo` is bidirectional: the client streams requests and
this service streams one response each, answering `list_services`,
`file_by_filename`, and `file_containing_symbol`. Extensions are a proto2
feature and report empty/not-found.

The served file descriptors come from gpb's `descriptor/0` (the
`descriptor` build option), which returns a `FileDescriptorSet`; this
module splits it into the per-file `FileDescriptorProto` bytes the
reflection protocol expects.

gpb describes a `map<>` field with a top-level `MapFieldEntry_N_M`
message shared by every field of the same map type, with `required`
key and value. protoc, and the clients that validate descriptors
(protoreflect, so grpcurl and Postman), expect one `<FieldName>Entry`
message nested in the owner of each map field, with `optional` key and
value. The split rewrites the entries into that shape.
""".

-include_lib("gpb/descr_src/gpb_descriptor.hrl").

-export([service/0, build/1]).
-export([server_reflection_info/2]).

-export_type([data/0]).

%% Reflection lookup tables, built once at server start.
-type data() :: #{
    services := [binary()],
    files := #{binary() => [binary()]},
    symbols := #{binary() => [binary()]}
}.

%% gRPC status codes used in error responses.
-define(NOT_FOUND, 5).
-define(UNIMPLEMENTED, 12).

%%====================================================================
%% Registration and data
%%====================================================================

-doc "The service spec to mount (done for you by `reflection => true`).".
-spec service() -> livery_grpc_service:registration().
service() ->
    #{proto => reflection_pb, service => 'ServerReflection', handler => ?MODULE}.

-doc """
Build the reflection lookup tables from the server's registrations: the
exposed service names, and, keyed by file name and by symbol, the
`FileDescriptorProto` bytes that define them.
""".
-spec build([livery_grpc_service:registration()]) -> data().
build(Registrations) ->
    Services = [
        livery_grpc_service:service_full_name(P, S)
     || #{proto := P, service := S} <- Registrations
    ],
    Protos = lists:usort([P || #{proto := P} <- Registrations]),
    {Files, Symbols} = lists:foldl(fun index_proto/2, {#{}, #{}}, Protos),
    #{services => Services, files => Files, symbols => Symbols}.

%% Index one proto module: map each of its file names and each symbol its
%% files define (services, methods, messages, enums, at any nesting and in
%% any package) to the module's descriptor files.
-spec index_proto(module(), {map(), map()}) -> {map(), map()}.
index_proto(Proto, {Files, Symbols}) ->
    Descriptors = file_descriptors(Proto),
    Fdps = [gpb_descriptor:encode_msg(D) || D <- Descriptors],
    Files1 = lists:foldl(
        fun(D, Acc) -> Acc#{to_binary(D#'FileDescriptorProto'.name) => Fdps} end,
        Files,
        Descriptors
    ),
    Symbols1 = lists:foldl(
        fun(Sym, Acc) -> Acc#{Sym => Fdps} end,
        Symbols,
        lists:flatmap(fun file_symbols/1, Descriptors)
    ),
    {Files1, Symbols1}.

%% The FileDescriptorProtos of a proto module (the file plus any
%% dependencies), from gpb's FileDescriptorSet, with map entries normalised.
-spec file_descriptors(module()) -> [gpb_descriptor:'FileDescriptorProto'()].
file_descriptors(Proto) ->
    #'FileDescriptorSet'{file = Files} =
        gpb_descriptor:decode_msg(Proto:descriptor(), 'FileDescriptorSet'),
    [normalize_file(File) || File <- list(Files)].

%% Fully qualified names (no leading dot) of everything a file defines.
-spec file_symbols(gpb_descriptor:'FileDescriptorProto'()) -> [binary()].
file_symbols(#'FileDescriptorProto'{} = File) ->
    Scope = scope(File#'FileDescriptorProto'.package),
    Names =
        lists:flatmap(
            fun(M) -> msg_symbols(Scope, M) end, list(File#'FileDescriptorProto'.message_type)
        ) ++
            [
                qualify(Scope, E#'EnumDescriptorProto'.name)
             || E <- list(File#'FileDescriptorProto'.enum_type)
            ] ++
            lists:flatmap(
                fun(S) -> service_symbols(Scope, S) end, list(File#'FileDescriptorProto'.service)
            ),
    [to_binary(tl(Name)) || Name <- Names].

-spec msg_symbols(string(), gpb_descriptor:'DescriptorProto'()) -> [string()].
msg_symbols(Scope, #'DescriptorProto'{} = Msg) ->
    Fqn = qualify(Scope, Msg#'DescriptorProto'.name),
    [Fqn] ++
        [
            qualify(Fqn, E#'EnumDescriptorProto'.name)
         || E <- list(Msg#'DescriptorProto'.enum_type)
        ] ++
        lists:flatmap(fun(N) -> msg_symbols(Fqn, N) end, list(Msg#'DescriptorProto'.nested_type)).

-spec service_symbols(string(), gpb_descriptor:'ServiceDescriptorProto'()) -> [string()].
service_symbols(Scope, #'ServiceDescriptorProto'{} = Service) ->
    Fqn = qualify(Scope, Service#'ServiceDescriptorProto'.name),
    [
        Fqn
        | [
            qualify(Fqn, M#'MethodDescriptorProto'.name)
         || M <- list(Service#'ServiceDescriptorProto'.method)
        ]
    ].

%%====================================================================
%% Map entry normalisation
%%====================================================================

%% Move gpb's top-level map entry messages to where protoc puts them: one
%% `<FieldName>Entry` nested in the owner of each map field.
-spec normalize_file(gpb_descriptor:'FileDescriptorProto'()) ->
    gpb_descriptor:'FileDescriptorProto'().
normalize_file(#'FileDescriptorProto'{message_type = Msgs0} = File) ->
    Msgs = list(Msgs0),
    Scope = scope(File#'FileDescriptorProto'.package),
    Entries =
        #{
            qualify(Scope, M#'DescriptorProto'.name) => M
         || M <- Msgs, is_map_entry(M)
        },
    File#'FileDescriptorProto'{
        message_type = [
            normalize_msg(M, Scope, Entries)
         || M <- Msgs, not is_map_entry(M)
        ]
    }.

-spec normalize_msg(gpb_descriptor:'DescriptorProto'(), string(), map()) ->
    gpb_descriptor:'DescriptorProto'().
normalize_msg(#'DescriptorProto'{} = Msg, Scope, Entries) ->
    Fqn = qualify(Scope, Msg#'DescriptorProto'.name),
    Nested = [normalize_msg(N, Fqn, Entries) || N <- list(Msg#'DescriptorProto'.nested_type)],
    {Fields, Added} = lists:mapfoldl(
        fun(Field, Acc) -> normalize_field(Field, Fqn, Entries, Acc) end,
        [],
        list(Msg#'DescriptorProto'.field)
    ),
    Msg#'DescriptorProto'{field = Fields, nested_type = Nested ++ lists:reverse(Added)}.

%% A field typed by a gpb map entry gets its own nested copy of the entry.
-spec normalize_field(gpb_descriptor:'FieldDescriptorProto'(), string(), map(), [
    gpb_descriptor:'DescriptorProto'()
]) ->
    {gpb_descriptor:'FieldDescriptorProto'(), [gpb_descriptor:'DescriptorProto'()]}.
normalize_field(#'FieldDescriptorProto'{type_name = undefined} = Field, _Fqn, _Entries, Acc) ->
    {Field, Acc};
normalize_field(#'FieldDescriptorProto'{type_name = TypeName} = Field, Fqn, Entries, Acc) ->
    case maps:find(to_string(TypeName), Entries) of
        {ok, Entry} ->
            Name = map_entry_name(to_string(Field#'FieldDescriptorProto'.name)),
            Entry1 = Entry#'DescriptorProto'{
                name = Name,
                field = [
                    F#'FieldDescriptorProto'{label = 'LABEL_OPTIONAL'}
                 || F <- list(Entry#'DescriptorProto'.field)
                ]
            },
            {Field#'FieldDescriptorProto'{type_name = qualify(Fqn, Name)}, [Entry1 | Acc]};
        error ->
            {Field, Acc}
    end.

-spec is_map_entry(gpb_descriptor:'DescriptorProto'()) -> boolean().
is_map_entry(#'DescriptorProto'{options = #'MessageOptions'{map_entry = true}}) -> true;
is_map_entry(#'DescriptorProto'{}) -> false.

%% protoc's entry name: the field name camel-cased, plus "Entry"
%% (`by_id` -> `ByIdEntry`).
-spec map_entry_name(string()) -> string().
map_entry_name(FieldName) ->
    camel(FieldName, true) ++ "Entry".

-spec camel(string(), boolean()) -> string().
camel([$_ | Rest], _Upper) -> camel(Rest, true);
camel([C | Rest], true) -> [string:to_upper(C) | camel(Rest, false)];
camel([C | Rest], false) -> [C | camel(Rest, false)];
camel([], _Upper) -> [].

%% The fully qualified prefix of a file's top-level names.
-spec scope(unicode:chardata() | undefined) -> string().
scope(undefined) -> "";
scope(Package) -> "." ++ to_string(Package).

-spec qualify(string(), unicode:chardata() | undefined) -> string().
qualify(Scope, Name) ->
    Scope ++ "." ++ to_string(Name).

-spec to_string(unicode:chardata() | undefined) -> string().
to_string(undefined) -> "";
to_string(Chars) -> unicode:characters_to_list(Chars).

-spec to_binary(unicode:chardata() | undefined) -> binary().
to_binary(Chars) -> unicode:characters_to_binary(to_string(Chars)).

-spec list([T] | undefined) -> [T].
list(undefined) -> [];
list(L) -> L.

%%====================================================================
%% Bidirectional handler
%%====================================================================

-doc "The `ServerReflectionInfo` bidirectional RPC.".
-spec server_reflection_info(livery_grpc_stream:stream(), livery_grpc_server:ctx()) ->
    ok | {error, term()}.
server_reflection_info(Stream, Ctx) ->
    Data = maps:get(reflection, Ctx, empty_data()),
    loop(Stream, Data).

-spec loop(livery_grpc_stream:stream(), data()) -> ok | {error, term()}.
loop(Stream, Data) ->
    case livery_grpc_stream:recv(Stream) of
        {ok, Request, Stream1} ->
            case livery_grpc_stream:send(Stream1, respond(Request, Data)) of
                ok -> loop(Stream1, Data);
                {error, _} = E -> E
            end;
        {eof, _Stream1} ->
            ok;
        {error, Reason, _Stream1} ->
            {error, {internal, format(Reason)}}
    end.

-spec respond(map(), data()) -> map().
respond(#{message_request := {list_services, _}} = Request, Data) ->
    Services = [#{name => N} || N <- maps:get(services, Data)],
    reply(Request, {list_services_response, #{service => Services}});
respond(#{message_request := {file_containing_symbol, Symbol}} = Request, Data) ->
    by_key(Request, Symbol, maps:get(symbols, Data));
respond(#{message_request := {file_by_filename, Name}} = Request, Data) ->
    by_key(Request, Name, maps:get(files, Data));
respond(#{message_request := {all_extension_numbers_of_type, Type}} = Request, _Data) ->
    reply(
        Request, {all_extension_numbers_response, #{base_type_name => Type, extension_number => []}}
    );
respond(#{message_request := {file_containing_extension, _}} = Request, _Data) ->
    error_reply(Request, ?NOT_FOUND, <<"extensions are not supported">>);
respond(Request, _Data) ->
    error_reply(Request, ?UNIMPLEMENTED, <<"unsupported reflection request">>).

-spec by_key(map(), binary(), #{binary() => [binary()]}) -> map().
by_key(Request, Key, Table) ->
    case maps:find(Key, Table) of
        {ok, Fdps} ->
            reply(Request, {file_descriptor_response, #{file_descriptor_proto => Fdps}});
        error ->
            error_reply(Request, ?NOT_FOUND, <<"symbol not found: ", Key/binary>>)
    end.

-spec reply(map(), tuple()) -> map().
reply(Request, MessageResponse) ->
    #{
        valid_host => maps:get(host, Request, <<>>),
        original_request => Request,
        message_response => MessageResponse
    }.

-spec error_reply(map(), integer(), binary()) -> map().
error_reply(Request, Code, Message) ->
    reply(Request, {error_response, #{error_code => Code, error_message => Message}}).

-spec empty_data() -> data().
empty_data() ->
    #{services => [], files => #{}, symbols => #{}}.

-spec format(term()) -> binary().
format(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).
