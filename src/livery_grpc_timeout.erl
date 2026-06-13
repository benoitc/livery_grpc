-module(livery_grpc_timeout).
-moduledoc """
The `grpc-timeout` header: a call deadline on the wire.

The value is an ASCII integer (up to 8 digits) followed by a unit:
`H` hours, `M` minutes, `S` seconds, `m` milliseconds, `u` microseconds,
`n` nanoseconds. This module converts between that wire form and a
millisecond timeout (the unit Erlang's `receive ... after` and timers
use). Sub-millisecond units round up to 1 ms so a deadline is never 0.
""".

-export([parse/1, encode/1]).

-doc """
Parse a `grpc-timeout` value into milliseconds. `undefined` (header
absent) yields `infinity`. A malformed value also yields `infinity`, so a
bad header relaxes the deadline rather than failing the call.
""".
-spec parse(binary() | undefined) -> timeout().
parse(undefined) ->
    infinity;
parse(Bin) when is_binary(Bin) ->
    case split_unit(Bin) of
        {Digits, Unit} ->
            try
                to_ms(binary_to_integer(Digits), Unit)
            catch
                error:_ -> infinity
            end;
        error ->
            infinity
    end.

-doc """
Encode a millisecond timeout as a `grpc-timeout` value. `infinity` returns
`undefined` (no header). Values that fit in 8 digits of milliseconds use
the `m` unit; larger deadlines fall back to whole seconds.
""".
-spec encode(timeout()) -> binary() | undefined.
encode(infinity) ->
    undefined;
encode(Ms) when is_integer(Ms), Ms >= 0, Ms =< 99999999 ->
    <<(integer_to_binary(Ms))/binary, "m">>;
encode(Ms) when is_integer(Ms), Ms > 99999999 ->
    Secs = (Ms + 999) div 1000,
    <<(integer_to_binary(Secs))/binary, "S">>.

%%====================================================================
%% Internals
%%====================================================================

-spec split_unit(binary()) -> {binary(), byte()} | error.
split_unit(<<>>) ->
    error;
split_unit(Bin) ->
    Size = byte_size(Bin) - 1,
    case Bin of
        <<Digits:Size/binary, Unit>> when Digits =/= <<>> -> {Digits, Unit};
        _ -> error
    end.

%% Convert an integer count in the given unit to milliseconds, rounding
%% sub-millisecond units up so a positive timeout never collapses to 0.
-spec to_ms(non_neg_integer(), byte()) -> non_neg_integer().
to_ms(N, $H) -> N * 3600000;
to_ms(N, $M) -> N * 60000;
to_ms(N, $S) -> N * 1000;
to_ms(N, $m) -> N;
to_ms(N, $u) -> ceil_div(N, 1000);
to_ms(N, $n) -> ceil_div(N, 1000000).

-spec ceil_div(non_neg_integer(), pos_integer()) -> non_neg_integer().
ceil_div(0, _) -> 0;
ceil_div(N, D) -> (N + D - 1) div D.
