# Status codes

Every gRPC call ends with a status code. livery_grpc represents the 16
canonical codes as atoms; `livery_grpc_status` converts between the atom,
the integer, and the wire value.

## The codes

| Atom | Code |
| --- | --- |
| `ok` | 0 |
| `cancelled` | 1 |
| `unknown` | 2 |
| `invalid_argument` | 3 |
| `deadline_exceeded` | 4 |
| `not_found` | 5 |
| `already_exists` | 6 |
| `permission_denied` | 7 |
| `resource_exhausted` | 8 |
| `failed_precondition` | 9 |
| `aborted` | 10 |
| `out_of_range` | 11 |
| `unimplemented` | 12 |
| `internal` | 13 |
| `unavailable` | 14 |
| `data_loss` | 15 |
| `unauthenticated` | 16 |

## Using them

Return a code atom from a handler:

```erlang
{error, permission_denied}
{error, {permission_denied, <<"token expired">>}}
```

Convert when you need to:

```erlang
3  = livery_grpc_status:code(invalid_argument),
invalid_argument = livery_grpc_status:name(3),
<<"5">> = livery_grpc_status:to_binary(not_found),
not_found = livery_grpc_status:from_binary(<<"5">>).
```

An unknown integer maps to `unknown`, so a peer using a code livery_grpc
does not model still yields a usable value.

## See also

- [Error handling](error-handling.md) for returning and reading errors.
