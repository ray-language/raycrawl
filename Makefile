# raycrawl — common tasks. `make` (or `make help`) lists them.

.DEFAULT_GOAL := help
.PHONY: help build test test-native fmt demo bench interop clean

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-12s %s\n", $$1, $$2}'

build: ## The native binary, ./raycrawl
	rm -f raycrawl
	ray build --native --release -o raycrawl src/main.ray

test: ## Tests on the VM (no internet: a local fixture site on port 0)
	ray test

test-native: ## The same tests as native binaries
	ray test --native

fmt: ## Format the sources
	ray fmt -w src/*.ray tests/*.ray

demo: build ## Crawl the local fixture site and print the summary
	./scripts/demo.sh

bench: build ## Pages/s against the local site: native vs VM, 1 vs N fetchers
	./scripts/bench.sh

interop: build ## OPTIONAL: robots + a 5-page crawl of one real public site (needs internet)
	./raycrawl robots https://www.rust-lang.org/
	./raycrawl crawl https://www.rust-lang.org/ --max-pages 5 --depth 1 --per-host 1 --delay 2000 --out interop.jsonl

clean: ## Remove the binary and crawl outputs
	rm -f raycrawl *.jsonl
