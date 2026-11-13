# raygrpc — common tasks. `make` (or `make help`) lists them.

.DEFAULT_GOAL := help
.PHONY: help build test test-native check fmt fixtures interop bench serve clean

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-12s %s\n", $$1, $$2}'

build: ## The native binary, ./raygrpc
	rm -f raygrpc
	ray build --native --release -o raygrpc src/main.ray

test: ## Tests on the VM
	ray test

test-native: ## The same tests as native binaries
	ray test --native

check: ## Type-check without running
	ray check

fmt: ## Format the sources
	ray fmt -w src/*.ray tests/*.ray

fixtures: ## Regenerate the protoc-made test fixtures (protoc is the oracle)
	./scripts/fixtures.sh

interop: build ## grpcurl and protoc as oracles against ./raygrpc (servers on random ports)
	./scripts/interop.sh

bench: build ## calls/s, VM and native, server and client (servers on random ports)
	./scripts/bench.sh

serve: ## The demo server on an ephemeral port, h2c, with reflection (Ctrl-C to stop)
	ray run src/main.ray serve

clean: ## Remove the binary and ./out
	rm -f raygrpc
	rm -rf out
