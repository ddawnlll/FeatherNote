ZIG ?= zig
BIN := zig-out/bin/feathernote

.PHONY: all build debug test integration bench run fmt clean

all: build

build:
	$(ZIG) build --release=safe

debug:
	$(ZIG) build

test:
	$(ZIG) build test

integration: build
	python3 tests/integration.py

bench: build
	python3 scripts/bench.py

run: debug
	$(ZIG) build run -- serve --db data/feathernote.db

fmt:
	$(ZIG) fmt src build.zig assets.zig

clean:
	rm -rf zig-out .zig-cache
