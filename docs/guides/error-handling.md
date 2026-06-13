# Error handling

A gRPC call ends with a status: `OK` on success, or one of the error codes
with an optional message and details. This guide shows how to return and
read them.

## Return an error from a handler

A handler returns one of:

```erlang
{ok, Reply}                      %% success
{error, Status}                  %% a status atom, no message
{error, {Status, Message}}       %% status and a human-readable message
{error, {Status, Message, Details}}  %% plus binary details (see below)
```

`Status` is a status atom such as `not_found` or `invalid_argument` (see
[status codes](status-codes.md)).

```erlang
get_user(#{id := Id}, _Ctx) ->
    case users:find(Id) of
        {ok, User} -> {ok, User};
        error      -> {error, {not_found, <<"no such user">>}}
    end.
```

You can also throw `{grpc_error, Status, Message}` from anywhere in the
handler; it is caught and turned into that status.

## Crashes become INTERNAL

If a handler crashes, the call fails with `internal` and the stream is
closed cleanly. The crash is not leaked to the client beyond a generic
message.

## Read an error on the client

A non-OK status comes back as an error tuple:

```erlang
case livery_grpc_client:call(Conn, Method, Request) of
    {ok, Reply}                  -> handle(Reply);
    {error, {Status, Message}}   -> handle_error(Status, Message);
    {error, {Status, Message, Details}} -> handle_error(Status, Message, Details)
end.
```

## Rich error details

To attach a machine-readable payload (for example an encoded
`google.rpc.Status`), return a third element. It is sent as the
`grpc-status-details-bin` trailer (base64) and the client receives the raw
bytes:

```erlang
%% server
{error, {failed_precondition, <<"needs setup">>, DetailsBin}}.

%% client
{error, {failed_precondition, <<"needs setup">>, DetailsBin}} =
    livery_grpc_client:call(Conn, Method, Request).
```

## See also

- [Status codes](status-codes.md) for the full list.
- [Deadlines](deadlines.md): an overrun returns `deadline_exceeded`.
