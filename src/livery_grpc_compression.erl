-module(livery_grpc_compression).
-moduledoc """
gRPC per-message compression.

Supports `identity` (no compression) and `gzip`. The active algorithm is
negotiated through the `grpc-encoding` (what this message used) and
`grpc-accept-encoding` (what the peer can decode) headers.

A frame's compressed flag (see `livery_grpc_frame`) says whether its
payload went through `compress/2`; `identity` always leaves the flag
clear.
""".

-export([compress/2, decompress/2]).
-export([is_supported/1, from_header/1, accept_header/0]).

-export_type([algorithm/0]).

-type algorithm() :: identity | gzip.

-doc """
Compress a payload. Returns `{Compressed, Bytes}`: `Compressed` is the
boolean to put in the frame flag. `identity` never marks the frame.
""".
-spec compress(algorithm(), binary()) -> {boolean(), binary()}.
compress(identity, Bin) ->
    {false, Bin};
compress(gzip, Bin) ->
    {true, zlib:gzip(Bin)}.

-doc """
Decompress a payload given the frame's compressed flag and the message
encoding. A clear flag means the payload is identity-coded regardless of
the negotiated algorithm (per the gRPC spec, the flag wins per message).
""".
-spec decompress(boolean(), algorithm()) -> fun((binary()) -> binary()).
decompress(false, _Algorithm) ->
    fun(Bin) -> Bin end;
decompress(true, gzip) ->
    fun(Bin) -> zlib:gunzip(Bin) end;
decompress(true, identity) ->
    %% Compressed flag set but the message declared identity: malformed.
    fun(_Bin) -> error({grpc_compression, flag_set_for_identity}) end.

-doc "Whether an algorithm atom is supported.".
-spec is_supported(algorithm() | term()) -> boolean().
is_supported(identity) -> true;
is_supported(gzip) -> true;
is_supported(_) -> false.

-doc """
Parse a `grpc-encoding` header value into an algorithm. An absent header
(`undefined`) or an unknown value falls back to `identity`.
""".
-spec from_header(binary() | undefined) -> algorithm().
from_header(undefined) -> identity;
from_header(<<"identity">>) -> identity;
from_header(<<"gzip">>) -> gzip;
from_header(_Other) -> identity.

-doc "The `grpc-accept-encoding` value advertising what we can decode.".
-spec accept_header() -> binary().
accept_header() ->
    <<"identity,gzip">>.
