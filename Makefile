.PHONY: bootstrap build test coverage coverage-html lint fmt clean bundle-vm official-keygen dev-keygen demo-packages demo-verify bundle-demos release-cli release-app docs man install acknowledgments notices

bootstrap:
	@echo "==> Installing Rust toolchain components..."
	rustup component add clippy rustfmt
	@echo "==> Installing cargo-about for license notices..."
	cargo install cargo-about
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

RUSTUP_TOOLCHAIN_BIN = $(shell rustup run stable rustc --print sysroot)/lib/rustlib/$(shell rustup run stable rustc -vV | awk '/^host:/{print $$2}')/bin
LLVM_COV     = $(RUSTUP_TOOLCHAIN_BIN)/llvm-cov
LLVM_PROFDATA = $(RUSTUP_TOOLCHAIN_BIN)/llvm-profdata

coverage:
	@echo "==> Checking for cargo-llvm-cov..."
	@cargo llvm-cov --version > /dev/null 2>&1 || (echo "cargo-llvm-cov not found. Install with: cargo install cargo-llvm-cov && rustup component add llvm-tools-preview" && exit 1)
	@echo "==> Running tests with coverage (vibe-cli)..."
	LLVM_COV=$(LLVM_COV) LLVM_PROFDATA=$(LLVM_PROFDATA) \
		cargo llvm-cov --package vibe-cli --summary-only
	@echo "==> For an HTML report: make coverage-html"

coverage-html:
	@echo "==> Generating HTML coverage report..."
	LLVM_COV=$(LLVM_COV) LLVM_PROFDATA=$(LLVM_PROFDATA) \
		cargo llvm-cov --package vibe-cli --html --open

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

# ──────────────────────────────────────────────────────────────────────────────
# Official key rotation
# ──────────────────────────────────────────────────────────────────────────────

# official-keygen: Generate a new official Vibe signing keypair.
#
# After running this target you must:
#   1. Copy the printed base64 value into the VIBE_SIGNING_KEY GitHub secret.
#   2. Commit the updated apps/mac-host/VibeHost/Resources/vibe-official.pub.
#   3. Run `make bundle-demos` to re-sign the bundled apps with the new key.
#
# The private key is written to signing/vibe-official.key (git-ignored).
# It is also printed as base64 once — store it in the GitHub secret immediately.
official-keygen: build
	@mkdir -p build/keygen signing
	@echo "==> Generating new official Vibe signing keypair..."
	@cargo run --bin vibe --quiet -- keygen -o build/keygen/vibe-official
	@cp build/keygen/vibe-official.key signing/vibe-official.key
	@cp build/keygen/vibe-official.pub apps/mac-host/VibeHost/Resources/vibe-official.pub
	@echo ""
	@echo "┌─────────────────────────────────────────────────────────────────────┐"
	@echo "│  New official keypair generated.                                    │"
	@echo "│                                                                     │"
	@echo "│  Private key → signing/vibe-official.key  (git-ignored)            │"
	@echo "│  Public key  → apps/mac-host/.../Resources/vibe-official.pub       │"
	@echo "│                                                                     │"
	@echo "│  VIBE_SIGNING_KEY (GitHub secret) — copy the value below:          │"
	@echo "└─────────────────────────────────────────────────────────────────────┘"
	@echo ""
	@base64 < build/keygen/vibe-official.key
	@echo ""
	@echo "  Next steps:"
	@echo "    1. Update the VIBE_SIGNING_KEY GitHub secret with the value above."
	@echo "    2. git add apps/mac-host/VibeHost/Resources/vibe-official.pub"
	@echo "    3. make bundle-demos   (re-sign the bundled apps)"
	@rm -f build/keygen/vibe-official.key build/keygen/vibe-official.pub

# ──────────────────────────────────────────────────────────────────────────────
# Developer demo packages  (signed with a local dev key)
# ──────────────────────────────────────────────────────────────────────────────

# dev-keygen: Generate a persistent local signing keypair for development.
# Creates build/dev/signing.{key,pub} once; does nothing if already present.
# Packages signed with this key will show "New Publisher" in the app (TOFU
# prompt on first open). This is expected for local development builds.
dev-keygen: build
	@mkdir -p build/dev
	@if [ -f build/dev/signing.key ]; then \
		echo "==> Dev signing key already exists at build/dev/signing.key — skipping."; \
	else \
		echo "==> Generating dev signing keypair at build/dev/signing..."; \
		cargo run --bin vibe -- keygen -o build/dev/signing; \
		echo "==> Dev keypair ready. Run 'make demo-packages' to build all demo apps."; \
	fi

# demo-packages: Package all example apps and sign them with the local dev key.
# Depends on dev-keygen (generates a key automatically if not present).
# Output goes to build/demo/ — nothing is copied to Resources.
demo-packages: dev-keygen
	@mkdir -p build/demo
	@echo "==> Packaging all demo projects (signed with dev key)..."
	@for dir in examples/nodejs-todo examples/python-api examples/static-site examples/ws-chat examples/sqlite-notes examples/postgres-bookmarks examples/redis-leaderboard examples/ui-none examples/ui-back-forward examples/ui-reload examples/ui-full; do \
		echo "  Packaging $$dir..."; \
		cargo run --bin vibe -- package $$dir/vibe.yaml -o build/demo/$$(basename $$dir).vibeapp; \
		cargo run --bin vibe -- sign build/demo/$$(basename $$dir).vibeapp --key build/dev/signing.key --embed-key; \
	done
	@echo "  Packaging examples/encrypted-notes (password-protected)..."
	cargo run --bin vibe -- package examples/encrypted-notes/vibe.yaml \
		-o build/demo/encrypted-notes.vibeapp \
		--seed-data examples/encrypted-notes-seed \
		--password demo1234
	cargo run --bin vibe -- sign build/demo/encrypted-notes.vibeapp \
		--key build/dev/signing.key \
		--password demo1234
	@echo "==> All demo packages ready in build/demo/"

# demo-verify: Verify all dev demo packages against the local dev public key.
demo-verify: demo-packages
	@echo "==> Verifying demo packages against dev key..."
	@for pkg in build/demo/*.vibeapp; do \
		if [ "$$(basename $$pkg)" = "encrypted-notes.vibeapp" ]; then \
			echo "  Verifying $$pkg (encrypted)..."; \
			cargo run --bin vibe -- verify $$pkg --key build/dev/signing.pub --password demo1234; \
		else \
			echo "  Verifying $$pkg..."; \
			cargo run --bin vibe -- verify $$pkg --key build/dev/signing.pub; \
		fi \
	done
	@echo "==> All demo packages verified."

# ──────────────────────────────────────────────────────────────────────────────
# Bundled app packages  (signed with the official Vibe key)
# ──────────────────────────────────────────────────────────────────────────────

# bundle-demos: Package and sign only the apps shipped inside the macOS bundle,
# then copy them to Resources/. These must be signed with the official Vibe key
# so they appear as "Verified" in the app without a trust prompt.
#
# Official key resolution (in order):
#   1. signing/vibe-official.key  — git-ignored file; place the private key here
#      for local use. See signing/README.md.
#   2. VIBE_SIGNING_KEY env var   — base64-encoded 32-byte key; set via the
#      GitHub Actions repository secret of the same name.
#
# Fails loudly if neither source is available.
#
# This target is intentionally independent of demo-packages.
bundle-demos: build
	@mkdir -p build/bundled
	@if [ -f signing/vibe-official.key ]; then \
		echo "==> Using signing/vibe-official.key..."; \
		cp signing/vibe-official.key build/bundled/.signing.key; \
	elif [ -n "$$VIBE_SIGNING_KEY" ]; then \
		echo "==> Using VIBE_SIGNING_KEY env var..."; \
		printf '%s' "$$VIBE_SIGNING_KEY" | base64 -d > build/bundled/.signing.key; \
	else \
		echo ""; \
		echo "ERROR: No official signing key found."; \
		echo ""; \
		echo "  To sign bundled apps locally, place the private key at:"; \
		echo "    signing/vibe-official.key"; \
		echo ""; \
		echo "  See signing/README.md for instructions."; \
		echo ""; \
		exit 1; \
	fi
	@echo "==> Packaging bundled apps (nodejs-todo, sqlite-notes, ws-chat)..."
	@for dir in examples/nodejs-todo examples/sqlite-notes examples/ws-chat; do \
		echo "  Packaging $$dir..."; \
		cargo run --bin vibe -- package $$dir/vibe.yaml -o build/bundled/$$(basename $$dir).vibeapp; \
		cargo run --bin vibe -- sign build/bundled/$$(basename $$dir).vibeapp --key build/bundled/.signing.key; \
	done
	@rm -f build/bundled/.signing.key
	@echo "==> Copying bundled apps to mac-host resources..."
	cp build/bundled/nodejs-todo.vibeapp build/bundled/sqlite-notes.vibeapp build/bundled/ws-chat.vibeapp \
		apps/mac-host/VibeHost/Resources/
	@echo "==> Bundled apps ready (Resources/ updated)."

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

docs:
	@echo "==> Starting Mintlify dev server..."
	mintlify dev

man:
	@echo "==> Generating man page..."
	cargo run --bin vibe-gen-man
	@echo "==> Man page written to man/vibe.1"

install: release-cli man
	@echo "==> Installing vibe CLI to /usr/local/bin..."
	install -d /usr/local/bin
	install -m 755 target/release/vibe /usr/local/bin/vibe
	@echo "==> Installing man page to /usr/local/share/man/man1..."
	install -d /usr/local/share/man/man1
	install -m 644 man/vibe.1 /usr/local/share/man/man1/vibe.1
	@echo "==> vibe installed (binary + man page)"

notices:
	@echo "==> Generating apps/cli/NOTICES via cargo-about..."
	@cargo about --version > /dev/null 2>&1 || (echo "cargo-about not found — run: make bootstrap" && exit 1)
	cargo about generate about.hbs -o apps/cli/NOTICES 2>/dev/null
	@echo "==> Commit apps/cli/NOTICES when deps change."

acknowledgments:
	@echo "==> Generating Acknowledgments.json from live package metadata..."
	@which python3 > /dev/null 2>&1 || (echo "python3 not found" && exit 1)
	python3 scripts/generate-acknowledgments.py
	@echo "==> Commit apps/mac-host/VibeHost/Resources/Acknowledgments.json when deps change."

clean:
	cargo clean
	cd apps/mac-host && swift package clean
	rm -rf build/demo build/dev build/bundled
