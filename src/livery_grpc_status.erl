-module(livery_grpc_status).
-moduledoc """
gRPC status codes and status metadata.

The 17 canonical codes (`0` `OK` through `16` `UNAUTHENTICATED`) as atoms,
with conversions to and from the integer used in the `grpc-status`
trailer/header. Also encodes and decodes the `grpc-message` value, which
uses gRPC's percent-encoding (only `%x20`-`%x7E` minus `%` pass through
literally; everything else is `%`-escaped).
""".

-export([code/1, name/1, is_code/1]).
-export([to_binary/1, from_binary/1]).
-export([encode_message/1, decode_message/1]).
-export([trailers/1, trailers/2]).

-export_type([code/0, status/0]).

-type status() ::
    ok
    | cancelled
    | unknown
    | invalid_argument
    | deadline_exceeded
    | not_found
    | already_exists
    | permission_denied
    | resource_exhausted
    | failed_precondition
    | aborted
    | out_of_range
    | unimplemented
    | internal
    | unavailable
    | data_loss
    | unauthenticated.

-type code() :: 0..16.

-define(IS_HEX(C),
    ((C >= $0 andalso C =< $9) orelse
        (C >= $a andalso C =< $f) orelse
        (C >= $A andalso C =< $F))
).

%%====================================================================
%% Code <-> name
%%====================================================================

-doc "The integer code for a status atom.".
-spec code(status()) -> code().
code(ok) -> 0;
code(cancelled) -> 1;
code(unknown) -> 2;
code(invalid_argument) -> 3;
code(deadline_exceeded) -> 4;
code(not_found) -> 5;
code(already_exists) -> 6;
code(permission_denied) -> 7;
code(resource_exhausted) -> 8;
code(failed_precondition) -> 9;
code(aborted) -> 10;
code(out_of_range) -> 11;
code(unimplemented) -> 12;
code(internal) -> 13;
code(unavailable) -> 14;
code(data_loss) -> 15;
code(unauthenticated) -> 16.

-doc """
The status atom for an integer code. Unknown integers map to `unknown`, so
a peer using a code we do not model still yields a usable value.
""".
-spec name(integer()) -> status().
name(0) -> ok;
name(1) -> cancelled;
name(2) -> unknown;
name(3) -> invalid_argument;
name(4) -> deadline_exceeded;
name(5) -> not_found;
name(6) -> already_exists;
name(7) -> permission_denied;
name(8) -> resource_exhausted;
name(9) -> failed_precondition;
name(10) -> aborted;
name(11) -> out_of_range;
name(12) -> unimplemented;
name(13) -> internal;
name(14) -> unavailable;
name(15) -> data_loss;
name(16) -> unauthenticated;
name(_) -> unknown.

-doc "Whether the term is a known status atom.".
-spec is_code(term()) -> boolean().
is_code(Atom) when is_atom(Atom) ->
    try
        _ = code(Atom),
        true
    catch
        error:function_clause -> false
    end;
is_code(_) ->
    false.

%%====================================================================
%% grpc-status header value
%%====================================================================

-doc "Render a status (atom or integer) as the `grpc-status` value.".
-spec to_binary(status() | code()) -> binary().
to_binary(Status) when is_atom(Status) ->
    integer_to_binary(code(Status));
to_binary(Code) when is_integer(Code) ->
    integer_to_binary(Code).

-doc "Parse a `grpc-status` value into a status atom.".
-spec from_binary(binary()) -> status().
from_binary(Bin) ->
    name(binary_to_integer(Bin)).

%%====================================================================
%% grpc-message percent-encoding
%%====================================================================

-doc """
Percent-encode a UTF-8 message for the `grpc-message` header. Printable
ASCII except `%` passes through; every other byte becomes `%XX`.
""".
-spec encode_message(binary()) -> binary().
encode_message(Msg) when is_binary(Msg) ->
    <<<<(encode_byte(B))/binary>> || <<B>> <= Msg>>.

-spec encode_byte(byte()) -> binary().
encode_byte($%) ->
    <<"%25">>;
encode_byte(B) when B >= 16#20, B =< 16#7E ->
    <<B>>;
encode_byte(B) ->
    <<$%, (hex(B bsr 4)), (hex(B band 16#0F))>>.

-spec hex(0..15) -> byte().
hex(N) when N < 10 -> $0 + N;
hex(N) -> $A + (N - 10).

-doc "Decode a percent-encoded `grpc-message` value.".
-spec decode_message(binary()) -> binary().
decode_message(Bin) ->
    decode_message(Bin, <<>>).

-spec decode_message(binary(), binary()) -> binary().
decode_message(<<$%, H, L, Rest/binary>>, Acc) when ?IS_HEX(H), ?IS_HEX(L) ->
    Byte = (unhex(H) bsl 4) bor unhex(L),
    decode_message(Rest, <<Acc/binary, Byte>>);
decode_message(<<B, Rest/binary>>, Acc) ->
    decode_message(Rest, <<Acc/binary, B>>);
decode_message(<<>>, Acc) ->
    Acc.

-spec unhex(byte()) -> 0..15.
unhex(C) when C >= $0, C =< $9 -> C - $0;
unhex(C) when C >= $a, C =< $f -> C - $a + 10;
unhex(C) when C >= $A, C =< $F -> C - $A + 10.

%%====================================================================
%% Trailers
%%====================================================================

-doc "Status trailers with no message.".
-spec trailers(status() | code()) -> [{binary(), binary()}].
trailers(Status) ->
    [{<<"grpc-status">>, to_binary(Status)}].

-doc "Status trailers carrying a (percent-encoded) message.".
-spec trailers(status() | code(), binary()) -> [{binary(), binary()}].
trailers(Status, <<>>) ->
    trailers(Status);
trailers(Status, Message) ->
    [
        {<<"grpc-status">>, to_binary(Status)},
        {<<"grpc-message">>, encode_message(Message)}
    ].
