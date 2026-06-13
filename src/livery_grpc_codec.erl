-module(livery_grpc_codec).
-moduledoc """
Protobuf encode/decode glue over a gpb-generated module.

A gpb module (e.g. `helloworld_pb`, built from `proto/helloworld.proto`)
exposes `encode_msg/2` and `decode_msg/2`. This module wraps them behind a
stable interface so the server and client do not call gpb directly, and so
an alternative codec (for example JSON for `application/grpc+json`) can be
slotted in later behind the same calls.

Encoding errors are surfaced as `{error, {encode|decode, Reason}}` rather
than raised, so the caller can turn them into a gRPC `internal` status.
""".

-export([encode/3, decode/3]).
-export([content_type/0, content_subtypes/0, is_grpc_content_type/1]).

-export_type([proto_module/0, msg_name/0]).

-type proto_module() :: module().
-type msg_name() :: atom().

-doc "Encode a message map/record to protobuf bytes.".
-spec encode(proto_module(), msg_name(), map() | tuple()) ->
    {ok, binary()} | {error, {encode, term()}}.
encode(Mod, MsgName, Msg) ->
    try
        {ok, iolist_to_binary(Mod:encode_msg(Msg, MsgName))}
    catch
        Class:Reason:Stack ->
            {error, {encode, {Class, Reason, Stack}}}
    end.

-doc "Decode protobuf bytes into a message map (gpb maps mode).".
-spec decode(proto_module(), msg_name(), binary()) ->
    {ok, map() | tuple()} | {error, {decode, term()}}.
decode(Mod, MsgName, Bin) ->
    try
        {ok, Mod:decode_msg(Bin, MsgName)}
    catch
        Class:Reason:Stack ->
            {error, {decode, {Class, Reason, Stack}}}
    end.

%%====================================================================
%% Content types
%%====================================================================

-doc "The default gRPC content type.".
-spec content_type() -> binary().
content_type() ->
    <<"application/grpc+proto">>.

-doc "Recognised gRPC content-type values for proto framing.".
-spec content_subtypes() -> [binary()].
content_subtypes() ->
    [<<"application/grpc">>, <<"application/grpc+proto">>].

-doc """
Whether a `content-type` header value names a gRPC proto request. A
trailing parameter (e.g. `;charset=...`) is tolerated; the base type is
matched.
""".
-spec is_grpc_content_type(binary() | undefined) -> boolean().
is_grpc_content_type(undefined) ->
    false;
is_grpc_content_type(Value) ->
    Base = base_type(Value),
    lists:member(Base, content_subtypes()).

-spec base_type(binary()) -> binary().
base_type(Value) ->
    case binary:split(Value, <<";">>) of
        [Base | _] -> trim(Base);
        [] -> Value
    end.

-spec trim(binary()) -> binary().
trim(Bin) ->
    string:trim(Bin).
