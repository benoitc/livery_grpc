-module(greeter_server).
-moduledoc """
Test fixture: a Greeter callback module for the helloworld service.

Implements the unary and server-streaming RPCs. The callback function
names are the RPC names in snake_case (see livery_grpc_service).
""".

-export([say_hello/2, say_hello_stream/3, say_hello_collect/2, say_hello_chat/2]).

%% Unary: greet by name. `boom` triggers an error status so the trailers
%% path is exercised.
say_hello(#{name := <<"boom">>}, _Ctx) ->
    {error, {invalid_argument, <<"no boom allowed">>}};
say_hello(#{name := <<"crash">>}, _Ctx) ->
    error(deliberate_crash);
say_hello(#{name := <<"slow">>}, _Ctx) ->
    timer:sleep(2000),
    {ok, #{message => <<"too late">>}};
say_hello(#{name := <<"details">>}, _Ctx) ->
    {error, {failed_precondition, <<"needs setup">>, <<"DETAILBYTES">>}};
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

%% Client-streaming: gather all names, reply once.
say_hello_collect(Stream, _Ctx) ->
    {ok, Requests, _Stream1} = livery_grpc_stream:recv_all(Stream),
    Names = [N || #{name := N} <- Requests],
    Joined = iolist_to_binary(lists:join(<<", ">>, Names)),
    {ok, #{message => <<"hello ", Joined/binary>>}}.

%% Bidirectional: echo a greeting per request as they arrive.
say_hello_chat(Stream, _Ctx) ->
    chat_loop(Stream).

chat_loop(Stream) ->
    case livery_grpc_stream:recv(Stream) of
        {ok, #{name := Name}, Stream1} ->
            _ = livery_grpc_stream:send(Stream1, #{message => <<"hi ", Name/binary>>}),
            chat_loop(Stream1);
        {eof, _Stream1} ->
            ok;
        {error, _Reason, _Stream1} ->
            {error, internal}
    end.
