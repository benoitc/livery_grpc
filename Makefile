.PHONY: compile proto eunit ct test dialyzer xref lint fmt check clean

compile:
	rebar3 compile

## Regenerate the *_pb.erl modules from proto/ without a full build.
proto:
	rebar3 protobuf compile

eunit:
	rebar3 eunit

ct:
	rebar3 ct

test: eunit ct

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
