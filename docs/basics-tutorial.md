# Basics tutorial

This tutorial builds RouteGuide, the canonical gRPC example, in Erlang. It
uses all four call types, so by the end you have seen every shape. The
complete code is in `examples/route_guide.erl` and `proto/route_guide.proto`.

## Define the service

```proto
syntax = "proto3";
package routeguide;

service RouteGuide {
  rpc GetFeature(Point) returns (Feature);
  rpc ListFeatures(Rectangle) returns (stream Feature);
  rpc RecordRoute(stream Point) returns (RouteSummary);
  rpc RouteChat(stream RouteNote) returns (stream RouteNote);
}

message Point     { int32 latitude = 1; int32 longitude = 2; }
message Rectangle { Point lo = 1; Point hi = 2; }
message Feature   { string name = 1; Point location = 2; }
message RouteNote { Point location = 1; string message = 2; }
message RouteSummary { int32 point_count = 1; int32 feature_count = 2; int32 distance = 3; }
```

`rebar3 compile` generates `route_guide_pb`. Nested messages are nested
maps: a `Feature` is `#{name => <<...>>, location => #{latitude => _, longitude => _}}`.

## Implement the four methods

The handler module exports one snake_case function per RPC.

### Unary: GetFeature

One request in, one reply out.

```erlang
get_feature(Point, _Ctx) ->
    {ok, #{name => feature_name(Point), location => Point}}.
```

### Server-streaming: ListFeatures

One request, many replies. A `Send` function pushes each reply; return
`ok` when done.

```erlang
list_features(#{lo := Lo, hi := Hi}, Send, _Ctx) ->
    lists:foreach(
        fun(#{location := Loc} = Feature) ->
            case in_rectangle(Loc, Lo, Hi) of
                true  -> Send(Feature);
                false -> ok
            end
        end,
        features()),
    ok.
```

### Client-streaming: RecordRoute

Many requests, one reply. Read the stream with `recv_all/1`, then return a
summary.

```erlang
record_route(Stream, _Ctx) ->
    {ok, Points, _} = livery_grpc_stream:recv_all(Stream),
    {ok, #{point_count   => length(Points),
           feature_count => count_named(Points),
           distance      => distance(Points)}}.
```

### Bidirectional: RouteChat

Both sides stream. Read with `recv/1`, reply with `send/2`, interleaved.
Here, each incoming note is echoed with any earlier note left at the same
point.

```erlang
route_chat(Stream, _Ctx) ->
    chat_loop(Stream, #{}).

chat_loop(Stream, Seen) ->
    case livery_grpc_stream:recv(Stream) of
        {ok, #{location := Loc, message := Msg}, Stream1} ->
            Prior = maps:get(Loc, Seen, []),
            [livery_grpc_stream:send(Stream1, #{location => Loc, message => M}) || M <- Prior],
            chat_loop(Stream1, Seen#{Loc => Prior ++ [Msg]});
        {eof, _} ->
            ok
    end.
```

## Run the server

```erlang
{ok, Server} = livery_grpc:start_server(#{
    port     => 50051,
    services => [#{proto => route_guide_pb, service => 'RouteGuide', handler => route_guide}]
}).
```

## Call it

Unary and server-streaming go through `call/3`:

```erlang
{ok, Conn} = livery_grpc_client:connect("localhost", 50051),
{ok, GF}   = livery_grpc_client:method(route_guide_pb, 'RouteGuide', 'GetFeature'),
{ok, Feature} = livery_grpc_client:call(Conn, GF, #{latitude => 1, longitude => 1}),

{ok, LF}   = livery_grpc_client:method(route_guide_pb, 'RouteGuide', 'ListFeatures'),
{ok, Features} = livery_grpc_client:call(Conn, LF, #{lo => ..., hi => ...}).
```

Client-streaming sends a list and gets one reply:

```erlang
{ok, RR} = livery_grpc_client:method(route_guide_pb, 'RouteGuide', 'RecordRoute'),
{ok, Summary} = livery_grpc_client:client_stream(Conn, RR, [Point1, Point2, Point3]).
```

Bidirectional opens a stream you drive with `send/2` and `recv/1`:

```erlang
{ok, RC}   = livery_grpc_client:method(route_guide_pb, 'RouteGuide', 'RouteChat'),
{ok, Call} = livery_grpc_client:open(Conn, RC),
ok = livery_grpc_client:send(Call, #{location => Loc, message => <<"hi">>}),
{ok, Note, Call1} = livery_grpc_client:recv(Call).
```

## Try it end to end

`route_guide:run/0` starts a server, calls all four methods, and prints
the results:

```
$ rebar3 as examples shell
1> route_guide:run().
```

With reflection on, grpcurl works without a `.proto`:

```
$ grpcurl -plaintext localhost:50051 list
$ grpcurl -plaintext -d '{"latitude":1,"longitude":1}' \
    localhost:50051 routeguide.RouteGuide/GetFeature
```
