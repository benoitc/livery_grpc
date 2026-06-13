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
""".

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

%% Index one proto module: map each of its file names and each symbol it
%% defines (services, messages, enums) to the module's descriptor files.
-spec index_proto(module(), {map(), map()}) -> {map(), map()}.
index_proto(Proto, {Files, Symbols}) ->
    Fdps = file_descriptors(Proto),
    Files1 = lists:foldl(fun(Fdp, Acc) -> Acc#{fdp_name(Fdp) => Fdps} end, Files, Fdps),
    Symbols1 = lists:foldl(fun(Sym, Acc) -> Acc#{Sym => Fdps} end, Symbols, symbols(Proto)),
    {Files1, Symbols1}.

%% The FileDescriptorProto bytes for a proto module (the file plus any
%% dependencies), extracted from gpb's FileDescriptorSet.
-spec file_descriptors(module()) -> [binary()].
file_descriptors(Proto) ->
    field1_values(Proto:descriptor()).

-spec symbols(module()) -> [binary()].
symbols(Proto) ->
    Package = livery_grpc_service:package(Proto),
    Names =
        Proto:get_service_names() ++ Proto:get_msg_names() ++ Proto:get_enum_names(),
    [livery_grpc_service:qualify(Package, atom_to_binary(N, utf8)) || N <- Names].

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

%%====================================================================
%% Minimal protobuf descriptor parsing
%%====================================================================

%% The FileDescriptorProto `name` field (field 1) as a binary.
-spec fdp_name(binary()) -> binary().
fdp_name(Fdp) ->
    case field1_values(Fdp) of
        [Name | _] -> Name;
        [] -> <<>>
    end.

%% Every length-delimited field-1 value at the top level of a protobuf
%% message. For a FileDescriptorSet that is each FileDescriptorProto; for a
%% FileDescriptorProto field 1 is its name.
-spec field1_values(binary()) -> [binary()].
field1_values(Bin) ->
    [V || {1, V} <- scan(Bin, [])].

%% Scan top-level fields, keeping length-delimited values as `{Field, Bin}`
%% and skipping everything else.
-spec scan(binary(), [{non_neg_integer(), binary()}]) -> [{non_neg_integer(), binary()}].
scan(<<>>, Acc) ->
    lists:reverse(Acc);
scan(Bin, Acc) ->
    {Tag, Rest} = varint(Bin),
    Field = Tag bsr 3,
    case Tag band 7 of
        2 ->
            {Len, Rest1} = varint(Rest),
            <<Value:Len/binary, Rest2/binary>> = Rest1,
            scan(Rest2, [{Field, Value} | Acc]);
        0 ->
            {_V, Rest1} = varint(Rest),
            scan(Rest1, Acc);
        1 ->
            <<_:8/binary, Rest1/binary>> = Rest,
            scan(Rest1, Acc);
        5 ->
            <<_:4/binary, Rest1/binary>> = Rest,
            scan(Rest1, Acc)
    end.

-spec varint(binary()) -> {non_neg_integer(), binary()}.
varint(Bin) ->
    varint(Bin, 0, 0).

-spec varint(binary(), non_neg_integer(), non_neg_integer()) -> {non_neg_integer(), binary()}.
varint(<<1:1, Group:7, Rest/binary>>, Shift, Acc) ->
    varint(Rest, Shift + 7, Acc bor (Group bsl Shift));
varint(<<0:1, Group:7, Rest/binary>>, Shift, Acc) ->
    {Acc bor (Group bsl Shift), Rest}.

-spec format(term()) -> binary().
format(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).
