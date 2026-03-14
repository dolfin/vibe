.PHONY: bootstrap generate build test lint fmt clean demo-packages demo-verify

bootstrap:
	@echo "==> Installing Rust toolchain components..."
	rustup component add clippy rustfmt
	@echo "==> Checking for protoc..."
	@which protoc > /dev/null 2>&1 || (echo "protoc not found. Install with: brew install protobuf" && exit 1)
	@echo "==> Checking for Swift..."
	@which swift > /dev/null 2>&1 || (echo "swift not found. Install Xcode Command Line Tools." && exit 1)
	@echo "==> Bootstrap complete."

generate:
	@echo "==> Generating protobuf code..."
	cd libs/rpc && cargo build

build: generate
	@echo "==> Building Rust workspace..."
	cargo build --workspace
	@echo "==> Building Swift host app..."
	cd apps/mac-host && swift build
	@echo "==> Build complete."

test:
	@echo "==> Running Rust tests..."
	cargo test --workspace
	@echo "==> Running Swift tests..."
	cd apps/mac-host && swift test
	@echo "==> All tests passed."

lint:
	@echo "==> Running clippy..."
	cargo clippy --workspace -- -D warnings
	@echo "==> Lint passed."

fmt:
	@echo "==> Formatting Rust code..."
	cargo fmt --all
	@echo "==> Format complete."

fmt-check:
	@echo "==> Checking Rust formatting..."
	cargo fmt --all -- --check
	@echo "==> Format check passed."

demo-packages: build
	@echo "==> Generating demo keypair..."
	@mkdir -p build/demo
	cargo run --bin vibe -- keygen -o build/demo/demo-signing
	@echo "==> Packaging demo projects..."
	@for dir in examples/nodejs-todo examples/python-api examples/static-site; do \
		echo "  Packaging $$dir..."; \
		cargo run --bin vibe -- package $$dir/vibe.yaml -o build/demo/$$(basename $$dir).vibeapp; \
		cargo run --bin vibe -- sign build/demo/$$(basename $$dir).vibeapp --key build/demo/demo-signing.key; \
	done
	@echo "==> Copying public key to mac-host resources..."
	cp build/demo/demo-signing.pub apps/mac-host/Sources/Resources/demo-signing.pub
	@echo "==> Demo packages ready in build/demo/"

demo-verify: demo-packages
	@echo "==> Verifying demo packages..."
	@for pkg in build/demo/*.vibeapp; do \
		echo "  Verifying $$pkg..."; \
		cargo run --bin vibe -- verify $$pkg --key build/demo/demo-signing.pub; \
	done
	@echo "==> All demo packages verified."

clean:
	cargo clean
	cd apps/mac-host && swift package clean
	rm -rf build/demo
