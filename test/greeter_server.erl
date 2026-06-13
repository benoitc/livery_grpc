-module(greeter_server).
-moduledoc """
Test fixture: a Greeter callback module for the helloworld service.

Implements the unary and server-streaming RPCs. The callback function
names are the RPC names in snake_case (see livery_grpc_service).
""".

-export([say_hello/2, say_hello_stream/3]).

%% Unary: greet by name. `boom` triggers an error status so the trailers
%% path is exercised.
say_hello(#{name := <<"boom">>}, _Ctx) ->
    {error, {invalid_argument, <<"no boom allowed">>}};
say_hello(#{name := <<"crash">>}, _Ctx) ->
    error(deliberate_crash);
say_hello(#{name := Name}, _Ctx) ->
    {ok, #{message => <<"hello ", Name/binary>>}};
say_hello(_Empty, _Ctx) ->
    {ok, #{message => <<"hello">>}}.

%% Server-streaming: one greeting per index.
say_hello_stream(#{name := Name}, Send, _Ctx) ->
    lists:foreach(
        fun(I) ->
            N = integer_to_binary(I),
            Send(#{message => <<"hi ", Name/binary, " #", N/binary>>})
        end,
        lists:seq(1, 3)
    ),
    ok.
