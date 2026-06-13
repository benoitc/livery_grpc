# Retry

Transient failures (a backend restart, a brief `unavailable`) often
succeed on a second try. A client interceptor retries them without
changing call sites. Only retry idempotent methods.

## A retry interceptor

A client interceptor is `fun((Request, Next) -> Result)`. This one retries
on a set of status codes, up to a limit:

```erlang
retry(Max, Codes) ->
    fun(Req, Next) ->
        case Next(Req) of
            {error, {Status, _}} = Err ->
                case Max > 0 andalso lists:member(Status, Codes) of
                    true  -> (retry(Max - 1, Codes))(Req, Next);
                    false -> Err
                end;
            Other ->
                Other
        end
    end.
```

Attach it per connection (or per call):

```erlang
Layer = retry(3, [unavailable, aborted]),
{ok, Conn} = livery_grpc_client:connect(Host, Port, #{interceptors => [Layer]}).
```

## Notes

- Retry only idempotent calls. A retried `create` can duplicate work.
- Add backoff between attempts (a `timer:sleep/1`, ideally with jitter)
  to avoid hammering a struggling backend.
- This runs around unary and server-streaming calls. See
  [interceptors](interceptors.md) for the layer model and
  [deadlines](deadlines.md) to bound the total time across retries.
