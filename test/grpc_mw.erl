-module(grpc_mw).
-moduledoc "Test middleware: bump a shared counter, then pass through.".

-behaviour(livery_middleware).

-export([call/3]).

call(Req, Next, Counter) ->
    counters:add(Counter, 1, 1),
    Next(Req).
