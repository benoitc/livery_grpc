-module(livery_grpc_web).
-moduledoc """
gRPC-Web framing.

gRPC-Web carries the same length-prefixed messages as gRPC, but the status
travels in the response body, not in HTTP trailers, so it works over
HTTP/1.1 and through browsers. The trailers are sent as a final frame
whose flag byte has the high bit set (`0x80`); its payload is an
HTTP/1.1-style `name:value\r\n` block.

Two content types: `application/grpc-web[+proto]` is binary;
`application/grpc-web-text` base64-encodes the whole body (request and
response). This module classifies the request content type and provides
the trailer frame plus the text base64 transforms.
""".

-export([mode/1, is_web/1, content_type/1]).
-export([trailer_frame/1, decode_request/2, encode_body/2]).

-export_type([mode/0]).

-type mode() :: grpc | grpc_web | grpc_web_text.

-doc """
Classify a request `content-type` into a mode, or `undefined` if it is not
a gRPC family type.
""".
-spec mode(binary() | undefined) -> mode() | undefined.
mode(undefined) ->
    undefined;
mode(Value) ->
    case base_type(Value) of
        <<"application/grpc">> -> grpc;
        <<"application/grpc+proto">> -> grpc;
        <<"application/grpc-web">> -> grpc_web;
        <<"application/grpc-web+proto">> -> grpc_web;
        <<"application/grpc-web-text">> -> grpc_web_text;
        <<"application/grpc-web-text+proto">> -> grpc_web_text;
        _ -> undefined
    end.

-doc "Whether a mode is one of the gRPC-Web variants.".
-spec is_web(mode()) -> boolean().
is_web(grpc) -> false;
is_web(grpc_web) -> true;
is_web(grpc_web_text) -> true.

-doc "The response `content-type` for a mode.".
-spec content_type(mode()) -> binary().
content_type(grpc) -> <<"application/grpc+proto">>;
content_type(grpc_web) -> <<"application/grpc-web+proto">>;
content_type(grpc_web_text) -> <<"application/grpc-web-text">>.

-doc """
Build the gRPC-Web trailer frame from a status header list (as
`livery_grpc_status:trailers/1,2` returns). The frame flag is `0x80`.
""".
-spec trailer_frame([{binary(), binary()}]) -> binary().
trailer_frame(StatusHeaders) ->
    Block = iolist_to_binary([[N, ":", V, "\r\n"] || {N, V} <- StatusHeaders]),
    <<128, (byte_size(Block)):32/big, Block/binary>>.

-doc "Decode a request body for a mode: base64 first for the text variant.".
-spec decode_request(mode(), binary()) -> binary().
decode_request(grpc_web_text, Body) -> base64:decode(Body);
decode_request(_Mode, Body) -> Body.

-doc "Encode a full response body for a mode: base64 for the text variant.".
-spec encode_body(mode(), iodata()) -> binary().
encode_body(grpc_web_text, Body) -> base64:encode(iolist_to_binary(Body));
encode_body(_Mode, Body) -> iolist_to_binary(Body).

%%====================================================================
%% Internals
%%====================================================================

-spec base_type(binary()) -> binary().
base_type(Value) ->
    case binary:split(Value, <<";">>) of
        [Base | _] -> string:trim(Base);
        [] -> Value
    end.
