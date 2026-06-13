.PHONY: compile proto stubs eunit ct test interop interop-client dialyzer xref lint fmt check clean

compile:
	rebar3 compile

## Regenerate the fixture *_pb.erl from proto/ (test profile).
proto:
	rebar3 as test protobuf compile

## Generate client stubs + service behaviours from a compiled proto module.
## Override PROTO and STUBS_OUT as needed, e.g. make stubs PROTO=my_pb.
PROTO ?= helloworld_pb
STUBS_OUT ?= gen
stubs: compile
	erl -noshell -pa _build/default/lib/*/ebin -pa _build/default/checkouts/*/ebin \
	  -eval 'io:format("~p~n", [livery_grpc_codegen:generate($(PROTO), "$(STUBS_OUT)")]), halt().'

eunit:
	rebar3 eunit

ct:
	rebar3 ct

test: eunit ct

## External compliance: drive our server with grpcurl (an external client).
## Skipped if grpcurl is not installed.
interop:
	./test/interop/grpcurl_smoke.sh

## Client interop: drive a real grpc-go server with our client. Skipped if
## Go is not installed.
interop-client:
	./test/interop/client_interop.sh

dialyzer:
	rebar3 dialyzer

xref:
	rebar3 xref

lint:
	rebar3 lint

fmt:
	rebar3 fmt --check

## Full offline gate: build, static checks, style, unit tests.
check: compile xref dialyzer lint fmt eunit

clean:
	rebar3 clean
