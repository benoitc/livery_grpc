-module(map_fixture).
-moduledoc """
Test fixture: the `MapEcho` service from `test/interop/mapfields.proto`,
a proto with `map<>` fields and a `google.protobuf.Struct`.

The proto is compiled in memory with the project's gpb options, so no
generated module ships in `src/`. Shared by the unit tests, the e2e suite
and `test/interop/grpcurl_smoke.sh`.
""".

-export([registration/0, echo/2]).

-define(PROTO, "mapfields.proto").

%% Compile and load `mapfields_pb` (once), and return its registration.
registration() ->
    case code:is_loaded(mapfields_pb) of
        {file, _} -> ok;
        false -> load()
    end,
    #{proto => mapfields_pb, service => 'MapEcho', handler => ?MODULE}.

%% Unary: reply with the request.
echo(Request, _Ctx) ->
    {ok, Request}.

load() ->
    {ok, Mod, Code} = gpb_compile:file(?PROTO, [
        binary,
        {i, proto_dir()},
        use_packages,
        {rename, {msg_fqname, base_name}},
        {rename, {service_fqname, base_name}},
        {module_name_suffix, "_pb"},
        {strings_as_binaries, true},
        {maps, true},
        {maps_unset_optional, omitted},
        descriptor
    ]),
    {module, Mod} = code:load_binary(Mod, "mapfields_pb.erl", Code),
    ok.

%% test/interop, next to this module's source or under the working dir.
proto_dir() ->
    Source = proplists:get_value(source, ?MODULE:module_info(compile), ""),
    Candidates = [
        filename:join(filename:dirname(Source), "interop"),
        filename:join(["test", "interop"])
    ],
    [Dir | _] = [D || D <- Candidates, filelib:is_regular(filename:join(D, ?PROTO))],
    Dir.
