-module(route_guide).
-moduledoc """
The RouteGuide example: the canonical gRPC service, in Erlang.

It implements all four call types over a small static map of features:

- `get_feature/2` (unary): the feature at a point.
- `list_features/3` (server-streaming): every feature in a rectangle.
- `record_route/2` (client-streaming): a route of points in, a summary out.
- `route_chat/2` (bidirectional): notes in, and any earlier note left at
  the same point streamed back.

Run it:

```
$ rebar3 as examples shell
1> route_guide:run().
```

Or start it and explore with grpcurl (reflection is on):

```
1> route_guide:start(50051).
$ grpcurl -plaintext localhost:50051 list
$ grpcurl -plaintext -d '{"latitude":1,"longitude":1}' \\
    localhost:50051 routeguide.RouteGuide/GetFeature
```
""".

%% Service callbacks (one Erlang function per RPC, snake_case).
-export([get_feature/2, list_features/3, record_route/2, route_chat/2]).
%% Demo helpers.
-export([start/1, run/0]).

%%====================================================================
%% Service callbacks
%%====================================================================

%% Unary: the feature at a point, or one with an empty name.
get_feature(Point, _Ctx) ->
    {ok, #{name => feature_name(Point), location => Point}}.

%% Server-streaming: send every feature inside the rectangle.
list_features(#{lo := Lo, hi := Hi}, Send, _Ctx) ->
    lists:foreach(
        fun(#{location := Loc} = Feature) ->
            case in_rectangle(Loc, Lo, Hi) of
                true -> Send(Feature);
                false -> ok
            end
        end,
        features()
    ),
    ok.

%% Client-streaming: read the whole route, reply with a summary.
record_route(Stream, _Ctx) ->
    {ok, Points, _Stream} = livery_grpc_stream:recv_all(Stream),
    Named = [P || P <- Points, feature_name(P) =/= <<>>],
    {ok, #{
        point_count => length(Points),
        feature_count => length(Named),
        distance => distance(Points)
    }}.

%% Bidirectional: for each incoming note, stream back the notes already
%% left at that point, then remember the new one (per call).
route_chat(Stream, _Ctx) ->
    chat_loop(Stream, #{}).

chat_loop(Stream, Seen) ->
    case livery_grpc_stream:recv(Stream) of
        {ok, #{location := Loc, message := Msg}, Stream1} ->
            Prior = maps:get(Loc, Seen, []),
            lists:foreach(
                fun(M) -> livery_grpc_stream:send(Stream1, #{location => Loc, message => M}) end,
                Prior
            ),
            chat_loop(Stream1, Seen#{Loc => Prior ++ [Msg]});
        {eof, _Stream1} ->
            ok;
        {error, _Reason, _Stream1} ->
            {error, internal}
    end.

%%====================================================================
%% Demo
%%====================================================================

-doc "Start a RouteGuide server on `Port` (h2c), with reflection.".
start(Port) ->
    {ok, _} = application:ensure_all_started(livery_grpc),
    livery_grpc:start_server(#{
        port => Port,
        reflection => true,
        services => [#{proto => route_guide_pb, service => 'RouteGuide', handler => ?MODULE}]
    }).

-doc "Start a server, call all four RPCs from a client, then stop.".
run() ->
    {ok, Server} = start(0),
    Port = livery_grpc:server_port(Server),
    {ok, Conn} = livery_grpc_client:connect("localhost", Port),
    try
        io:format("GetFeature: ~p~n", [
            livery_grpc_client:call(Conn, m('GetFeature'), #{latitude => 1, longitude => 1})
        ]),
        io:format("ListFeatures: ~p~n", [
            livery_grpc_client:call(Conn, m('ListFeatures'), #{
                lo => #{latitude => 0, longitude => 0},
                hi => #{latitude => 10, longitude => 10}
            })
        ]),
        io:format("RecordRoute: ~p~n", [
            livery_grpc_client:client_stream(Conn, m('RecordRoute'), [
                #{latitude => 1, longitude => 1}, #{latitude => 5, longitude => 5}
            ])
        ]),
        {ok, Chat} = livery_grpc_client:open(Conn, m('RouteChat')),
        ok = livery_grpc_client:send(Chat, #{
            location => #{latitude => 1, longitude => 1}, message => <<"first">>
        }),
        ok = livery_grpc_client:send(Chat, #{
            location => #{latitude => 1, longitude => 1}, message => <<"second">>
        }),
        io:format("RouteChat echo: ~p~n", [livery_grpc_client:recv(Chat)])
    after
        livery_grpc_client:close(Conn),
        livery_grpc:stop_server(Server)
    end,
    ok.

%%====================================================================
%% Data and helpers
%%====================================================================

m(Name) ->
    {ok, M} = livery_grpc_client:method(route_guide_pb, 'RouteGuide', Name),
    M.

features() ->
    [
        #{name => <<"Point One">>, location => #{latitude => 1, longitude => 1}},
        #{name => <<"Point Five">>, location => #{latitude => 5, longitude => 5}},
        #{name => <<"Point Far">>, location => #{latitude => 99, longitude => 99}}
    ].

feature_name(Point) ->
    case lists:search(fun(#{location := Loc}) -> Loc =:= Point end, features()) of
        {value, #{name := Name}} -> Name;
        false -> <<>>
    end.

in_rectangle(#{latitude := Lat, longitude := Lon}, #{latitude := LoLat, longitude := LoLon}, #{
    latitude := HiLat, longitude := HiLon
}) ->
    Lat >= min(LoLat, HiLat) andalso Lat =< max(LoLat, HiLat) andalso
        Lon >= min(LoLon, HiLon) andalso Lon =< max(LoLon, HiLon).

%% Manhattan distance along the route (kept integer for the example).
distance([_ | _] = Points) ->
    Pairs = lists:zip(lists:droplast(Points), tl(Points)),
    lists:sum([
        abs(LatB - LatA) + abs(LonB - LonA)
     || {#{latitude := LatA, longitude := LonA}, #{latitude := LatB, longitude := LonB}} <- Pairs
    ]);
distance(_) ->
    0.
