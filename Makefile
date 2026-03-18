.PHONY: bootstrap build test lint fmt clean bundle-vm demo-packages demo-verify release-cli release-app

bootstrap:
	@echo "==> Installing Rust toolchain components..."
	rustup component add clippy rustfmt
	@echo "==> Checking for Swift..."
	@which swift > /dev/null 2>&1 || (echo "swift not found. Install Xcode Command Line Tools." && exit 1)
	@echo "==> Bootstrap complete."

build:
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

bundle-vm:
	@echo "==> Building VM image..."
	cd vm-image && bash build.sh
	@echo "==> Copying kernel and initrd to mac-host resources..."
	@mkdir -p apps/mac-host/VibeHost/Resources
	cp vm-image/dist/kernel apps/mac-host/VibeHost/Resources/kernel
	cp vm-image/dist/initrd apps/mac-host/VibeHost/Resources/initrd
	@echo "==> VM image bundled (kernel + initrd in Resources/)"

demo-packages: build
	@echo "==> Generating demo keypair..."
	@mkdir -p build/demo
	@rm -f build/demo/demo-signing.key build/demo/demo-signing.pub
	cargo run --bin vibe -- keygen -o build/demo/demo-signing
	@echo "==> Packaging demo projects..."
	@for dir in examples/nodejs-todo examples/python-api examples/static-site examples/ws-chat examples/sqlite-notes examples/postgres-bookmarks examples/redis-leaderboard examples/ui-none examples/ui-back-forward examples/ui-reload examples/ui-full; do \
		echo "  Packaging $$dir..."; \
		cargo run --bin vibe -- package $$dir/vibe.yaml -o build/demo/$$(basename $$dir).vibeapp; \
		cargo run --bin vibe -- sign build/demo/$$(basename $$dir).vibeapp --key build/demo/demo-signing.key; \
	done
	@echo "  Packaging examples/encrypted-notes (password-protected)..."
	cargo run --bin vibe -- package examples/encrypted-notes/vibe.yaml \
		-o build/demo/encrypted-notes.vibeapp \
		--seed-data examples/encrypted-notes-seed \
		--password demo1234
	cargo run --bin vibe -- sign build/demo/encrypted-notes.vibeapp \
		--key build/demo/demo-signing.key \
		--password demo1234
	@echo "==> Copying public key to mac-host resources..."
	cp build/demo/demo-signing.pub apps/mac-host/VibeHost/Resources/demo-signing.pub
	@echo "==> Demo packages ready in build/demo/"

demo-verify: demo-packages
	@echo "==> Verifying demo packages..."
	@for pkg in build/demo/*.vibeapp; do \
		if [ "$$(basename $$pkg)" = "encrypted-notes.vibeapp" ]; then \
			echo "  Verifying $$pkg (encrypted)..."; \
			cargo run --bin vibe -- verify $$pkg --key build/demo/demo-signing.pub --password demo1234; \
		else \
			echo "  Verifying $$pkg..."; \
			cargo run --bin vibe -- verify $$pkg --key build/demo/demo-signing.pub; \
		fi \
	done
	@echo "==> All demo packages verified."

release-cli:
	@echo "==> Building release CLI..."
	cargo build --release
	@echo "==> CLI binary at target/release/vibe"

release-app:
	@echo "==> Archiving macOS app..."
	xcodebuild archive \
		-project apps/mac-host/VibeHost.xcodeproj \
		-scheme Vibe \
		-configuration Release \
		-archivePath build/Vibe.xcarchive
	@echo "==> Exporting archive..."
	xcodebuild -exportArchive \
		-archivePath build/Vibe.xcarchive \
		-exportOptionsPlist apps/mac-host/ExportOptions.plist \
		-exportPath build/export/
	@echo "==> App exported to build/export/"

clean:
	cargo clean
	cd apps/mac-host && swift package clean
	rm -rf build/demo
