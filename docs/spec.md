# Vibe Runtime --- Full Implementation Specification

Version: v1

0. Define the v1 scope

Lock the first release before you write code.

Decide that v1 supports:
	•	macOS app host
	•	one persistent Linux VM
	•	one containerd daemon in the VM
	•	one namespace per opened app
	•	immutable package + mutable state
	•	snapshot save/restore
	•	native manifest
	•	Compose import mode
	•	SQLite and Postgres persistence
	•	host port forwarding
	•	logs, start, stop, save, restore, duplicate

Explicitly defer:
	•	multi-user collaboration
	•	cloud sync
	•	distributed snapshots
	•	live migration
	•	build-your-own image pipeline in the app UI
	•	arbitrary Compose fidelity beyond your supported subset

Deliverable:
	•	docs/v1-scope.md

Acceptance:
	•	every feature in scope maps to an owner and test plan
	•	every non-v1 feature is listed as deferred, not implied

⸻

1. Create the repo layout

Set up a monorepo.

/vibe
  /apps
    /mac-host
    /vm-supervisor
    /cli
  /libs
    /manifest
    /snapshot
    /rpc
    /state-index
    /compose-import
    /signing
    /container-runtime
  /vm
    /image-builder
    /cloud-init
    /bootstrap
  /ops
    /ci
    /release
    /notarization
  /docs

Use one language per layer unless you have a strong reason not to.

Recommended stack:
	•	macOS host: Swift
	•	VM supervisor: Go
	•	CLI/dev tools: Go
	•	manifest/signature tooling: Go or Rust
	•	UI frontend: SwiftUI

Deliverables:
	•	workspace config
	•	linting
	•	formatting
	•	CI
	•	release channels

Acceptance:
	•	one command bootstraps the whole workspace
	•	one command runs all tests
	•	one command builds host app + supervisor + VM image

⸻

2. Freeze the architecture contracts first

Before coding internals, define the stable contracts.

Write these specs:
	•	docs/manifest-v1.md
	•	docs/state-layout-v1.md
	•	docs/rpc-api-v1.md
	•	docs/snapshot-protocol-v1.md
	•	docs/compose-compat-v1.md
	•	docs/security-model-v1.md

2.1 Manifest v1

Define the exact fields.

Example:

kind: vibe.app/v1
id: com.example.todo
name: Todo App
version: 1.0.0
icon: assets/icon.png

runtime:
  mode: native # native | compose
  composeFile: compose.yaml

services:
  - name: web
    image: ghcr.io/example/todo-web:1.0.0
    command: ["node", "server.js"]
    env:
      NODE_ENV: production
    ports:
      - container: 3000
        hostExposure: auto
    mounts:
      - source: state:uploads
        target: /data/uploads
    dependsOn: ["db"]

  - name: db
    image: postgres:16
    env:
      POSTGRES_DB: todo
      POSTGRES_USER: todo
    stateVolumes:
      - dbdata:/var/lib/postgresql/data

state:
  autosave: true
  autosaveDebounceSeconds: 30
  retention:
    maxSnapshots: 100
  volumes:
    - name: dbdata
      consistency: postgres
    - name: uploads
      consistency: generic

security:
  network: true
  allowHostFileImport: true

publisher:
  name: Example Inc.
  signing:
    scheme: ed25519
    signatureFile: signatures/package.sig
    publicKeyFile: signatures/publisher.pub

Lock validation rules now.

2.2 State layout v1

Define exact on-disk layout.

state/
  current/
    files/
    volumes/
    runtime/
      env.json
      ports.json
      service-state.json
  snapshots/
    2026-03-13T12-00-00Z/
      files/
      volumes/
      metadata.json
  index.json

2.3 RPC API v1

Define message schemas before implementation.
Use protobuf.

Services:
	•	EnsureProject
	•	OpenProject
	•	StartProject
	•	StopProject
	•	DeleteProjectRuntime
	•	ListProjects
	•	GetProjectStatus
	•	GetProjectLogs
	•	SaveSnapshot
	•	RestoreSnapshot
	•	ListSnapshots
	•	DuplicateProject
	•	ImportPackage
	•	ValidateCompose
	•	ResolvePorts

Acceptance:
	•	every future subsystem builds against these contracts
	•	no internal code invents its own ad hoc format later

⸻

3. Build the packaging toolchain

You need a developer tool before the app host.

Create vibe.

Commands:
	•	vibe init
	•	vibe validate
	•	vibe package
	•	vibe sign
	•	vibe verify
	•	vibe import-compose
	•	vibe inspect

3.1 Package format

Choose one:
	•	zipped archive with deterministic ordering
	•	bundle directory
	•	content-addressed package with manifest digest

For v1, use a deterministic archive plus extracted runtime copy.

Package creation algorithm:
	1.	read manifest
	2.	validate schema
	3.	normalize paths
	4.	reject path traversal
	5.	hash every file
	6.	build package manifest with file digests
	7.	sign root manifest
	8.	emit .vibeapp

3.2 Signature verification

Implement:
	•	root manifest hash
	•	detached signature
	•	publisher public key
	•	verification result with reason codes

Acceptance:
	•	tampering any package file breaks verification
	•	modifying state does not break package verification
	•	package verification is deterministic in CI

⸻

4. Build the VM image pipeline

Do not handcraft the VM image manually.

Create a reproducible image pipeline.

Outputs:
	•	Linux kernel
	•	initrd if needed
	•	root filesystem image
	•	first-boot seed
	•	version metadata

Inside the VM image include:
	•	systemd
	•	containerd
	•	runc
	•	CNI plugins
	•	nerdctl
	•	your vibe-supervisor
	•	your save hooks
	•	vsock agent
	•	log rotation
	•	health services

4.1 Pick the guest OS

Pick one and freeze it.
Use a minimal distro with good package support and predictable kernel behavior.

4.2 Bootstrap components

Install and pin versions for:
	•	containerd
	•	runc
	•	iptables or nftables tooling
	•	CNI plugins
	•	nerdctl
	•	sqlite3
	•	Postgres client tools
	•	archiving/compression tooling
	•	your supervisor binary

4.3 First boot

First boot should:
	1.	create /vibe
	2.	create runtime directories
	3.	configure containerd
	4.	configure CNI
	5.	enable supervisor service
	6.	write image version metadata
	7.	expose a ready signal over vsock

Acceptance:
	•	from a clean machine, the host can boot the VM and receive “ready”
	•	containerd starts automatically
	•	a sample container can run without manual shell steps

⸻

5. Build the macOS VM manager

This is the first real host app subsystem.

Use Apple Virtualization framework and add the required entitlement in the app project. The framework supports configuring Linux VMs and a virtio file system device for host resource sharing.  ￼

Responsibilities:
	•	create VM config
	•	boot VM
	•	stop VM
	•	restart VM
	•	report health
	•	manage disk image paths
	•	expose vsock connection to RPC client
	•	mount host shared directories if used

5.1 VM configuration

Implement:
	•	memory sizing policy
	•	CPU count policy
	•	disk attachment
	•	virtio network
	•	vsock device
	•	optional virtio-fs share
	•	boot loader/kernel/initrd configuration

5.2 VM lifecycle state machine

Create an explicit state machine.

Stopped
  -> Booting
  -> Ready
  -> Busy
  -> Paused
  -> ShuttingDown
  -> Stopped
  -> Error

Do not let UI code manipulate VM state directly.

Acceptance:
	•	boot succeeds repeatedly
	•	forced shutdown is recoverable
	•	VM manager survives app relaunch and can reconnect

⸻

6. Build the supervisor daemon in the VM

This is the core of the whole system.

Use Go.

Supervisor modules:
	•	package importer
	•	project registry
	•	runtime planner
	•	containerd client
	•	snapshot manager
	•	log collector
	•	DB consistency hooks
	•	port resolver
	•	health checker
	•	compose importer
	•	state reconciler

containerd’s client model is intentionally “smart client,” so keep orchestration in your supervisor rather than trying to push business logic into the daemon.  ￼

6.1 Project registry

Maintain a persistent registry:

{
  "projects": [
    {
      "projectId": "uuid",
      "appId": "com.example.todo",
      "namespace": "vibe_com.example.todo_abcd",
      "packagePath": "/vibe/apps/.../package",
      "statePath": "/vibe/apps/.../state",
      "status": "running",
      "ports": [{"service":"web","host":49231,"container":3000}]
    }
  ]
}

6.2 Namespace model

Each project gets one containerd namespace. containerd documents namespaces as a way for multiple consumers to share one daemon without conflicting while sharing content.  ￼

Namespace naming:
	•	stable but collision-safe
	•	based on app id + project id hash

6.3 Runtime planner

Convert manifest into an internal plan:
	•	services
	•	images
	•	mounts
	•	environment
	•	health checks
	•	dependencies
	•	volumes
	•	networking
	•	port exposure
	•	save hooks

Acceptance:
	•	supervisor can read a native manifest and produce a deterministic runtime plan
	•	plan serialization is stable for tests

⸻

7. Build the container runtime adapter

This layer hides containerd details from the rest of the supervisor.

Interfaces:
	•	EnsureImage
	•	EnsureNamespace
	•	EnsureNetwork
	•	EnsureVolume
	•	CreateService
	•	StartService
	•	StopService
	•	DeleteService
	•	GetLogs
	•	InspectService
	•	ListServices

7.1 Image handling

Implement:
	•	pull by digest preferred
	•	tag resolution policy
	•	retry policy
	•	local cache inspection
	•	disk usage accounting
	•	image GC marks

7.2 Network handling

Implement:
	•	one network per project
	•	internal DNS/service discovery naming
	•	optional host port mapping
	•	collision-safe host port allocator
	•	cleanup on project delete

7.3 Volume handling

Implement:
	•	namespace-scoped named volumes
	•	bind-style mounts from extracted state area
	•	mount policy validation
	•	path traversal prevention

Acceptance:
	•	one sample app with web + db can start and communicate
	•	two projects can run with no network collision
	•	image layers are reused between projects

⸻

8. Build Compose import mode

Your manifest may point at an existing Compose file. nerdctl supports Compose, but its docs explicitly call out unimplemented YAML fields, so do not treat Compose as lossless input.  ￼

8.1 Compose import strategy

Do not make Compose your runtime truth.
Implement this pipeline:
	1.	locate compose file
	2.	parse and validate
	3.	normalize service definitions
	4.	reject unsupported fields
	5.	rewrite host-path assumptions to VM-local paths
	6.	map services to your internal runtime model
	7.	generate an import report

8.2 Unsupported Compose policy

Create three buckets:
	•	supported
	•	supported with transformation
	•	rejected

Examples of likely transformations:
	•	build -> optional offline prebuild/import flow
	•	relative bind mounts -> remap into imported workspace
	•	depends_on -> startup ordering plus health checks

8.3 Compatibility CLI

Use nerdctl compose only as:
	•	a validation oracle in development
	•	an optional debug path
	•	a fallback for edge-case developer workflows

Do not make production project lifecycle depend on shelling out to CLI commands.

Acceptance:
	•	import report clearly explains every transformed or rejected field
	•	imported compose app runs through native supervisor logic
	•	at least 20 fixture compose files exist in tests

⸻

9. Build immutable package import and mutable state materialization

When a user opens a .vibeapp, the host should:
	1.	verify package signature
	2.	compute package identity
	3.	create or locate project instance
	4.	materialize immutable package into host cache
	5.	create or locate mutable state
	6.	ask supervisor to import/open project

9.1 Package cache

Use a content-addressed cache:

~/Library/Application Support/Vibe/package-cache/<sha256>/

9.2 Project instance model

A single app package may have many project instances.
Define instance identity separately from package identity.

Example:
	•	package = app definition
	•	project instance = one user’s mutable universe

9.3 Materialization

Package mounts read-only.
State mounts read-write.

Acceptance:
	•	opening same app twice can either reuse or duplicate state by explicit policy
	•	package cache deduplicates identical packages
	•	deleting one project instance does not remove shared package cache if still referenced

⸻

10. Build the snapshot engine

This is one of the hardest parts. Treat it like a product of its own.

10.1 Snapshot object model

Every snapshot stores:
	•	snapshot id
	•	timestamp
	•	parent snapshot id
	•	reason (manual, autosave, before-upgrade, before-restore)
	•	app version
	•	state digest
	•	volume manifests
	•	optional DB exports
	•	labels

10.2 Save algorithm

Generic save flow:
	1.	resolve target project
	2.	block new write-affecting lifecycle operations
	3.	run pre-save hooks per service
	4.	wait for quiesce
	5.	checkpoint state
	6.	copy current state to snapshot workspace
	7.	compute snapshot metadata
	8.	atomically update index.json
	9.	release lock
	10.	resume services

10.3 SQLite consistency

Per volume/file marked sqlite:
	1.	ensure no write migration running
	2.	run WAL checkpoint
	3.	fsync DB and directory
	4.	copy DB artifact
	5.	record integrity result

10.4 Postgres consistency

Do not snapshot the raw Postgres data dir as your only backup format.
Use one of:
	•	temporary stop + cold copy
	•	logical dump
	•	both

For v1:
	•	use logical dump for portable snapshots
	•	optionally keep raw volume copy for fast local restore

10.5 Generic volume consistency

For arbitrary volumes:
	•	stop or pause write-heavy containers if hook unavailable
	•	tar or chunk-copy volume
	•	hash manifest
	•	compress in background if needed

10.6 Snapshot storage format

Use chunked content store:
	•	split large files into fixed or content-defined chunks
	•	deduplicate by digest
	•	snapshot manifest references chunk digests

Acceptance:
	•	save/restore round trips on SQLite and Postgres fixtures
	•	partial save failure never corrupts current
	•	crash during save leaves last good snapshot intact

⸻

11. Build restore, revert, duplicate, and upgrade flows

11.1 Restore

Algorithm:
	1.	stop project services
	2.	verify target snapshot exists and matches project
	3.	stage restored state into temp area
	4.	validate restored metadata
	5.	swap temp into current atomically
	6.	record restore event
	7.	restart services
	8.	run post-restore health checks

11.2 Duplicate

Algorithm:
	1.	create new project id
	2.	copy package reference only
	3.	clone current state from source snapshot
	4.	allocate new namespace and ports
	5.	start duplicated project

11.3 Upgrade package version

Algorithm:
	1.	verify new package
	2.	compare manifest schemas
	3.	determine state migration need
	4.	take safety snapshot
	5.	run app-provided migration hooks if allowed
	6.	switch package mount to new immutable package
	7.	run health checks
	8.	allow rollback to prior package + snapshot

Acceptance:
	•	duplicate creates independent mutable state
	•	package upgrade can roll back
	•	restore does not leak old ports or networks

⸻

12. Build logging, events, and observability

Without this, you will not debug production.

12.1 Event stream

Everything emits structured events:
	•	vm boot
	•	package verify
	•	project open
	•	image pull
	•	service start
	•	save begin/end
	•	restore begin/end
	•	health failure
	•	cleanup
	•	GC

12.2 Logs

Collect:
	•	service stdout/stderr
	•	supervisor logs
	•	VM boot logs
	•	host app logs

12.3 Diagnostics bundle

Implement Export Diagnostics:
	•	redacted config
	•	event log
	•	relevant container logs
	•	resource summary
	•	image versions
	•	snapshot index

Acceptance:
	•	one click produces a support bundle
	•	every fatal error has traceable context

⸻

13. Build the host app UX

Now build the visible product.

### 13.0 Design philosophy

The Vibe macOS application is a **consumer-first product**. The primary UI must hide almost all infrastructure complexity (VMs, containers, networking, namespaces, etc.).

UI principles:
- simple mental model: "open apps, run them, save them"
- no container or VM terminology exposed to end users
- minimal configuration required
- safe defaults everywhere
- clear actions: Run, Stop, Save, Restore, Duplicate

Advanced runtime details should **not** appear in the standard UI.

Screens:
	•	Library
	•	Open app
	•	Running projects
	•	Project detail
	•	Logs
	•	Snapshots
	•	Settings
	•	Diagnostics

13.1 Open flow

When user opens a file:
	•	verify signature
	•	show publisher identity
	•	show requested capabilities
	•	choose state behavior: open existing / create new / duplicate
	•	launch

13.2 Project detail

Show:
	•	app name/version
	•	package trust status
	•	running services
	•	exposed ports
	•	CPU/RAM/disk
	•	current state size
	•	autosave status
	•	snapshots
	•	actions

13.3 Snapshot UI

Allow:
	•	save now
	•	auto-save toggle
	•	add label
	•	restore
	•	duplicate from snapshot
	•	delete snapshot

Acceptance:
	•	all backend actions reachable from UI
	•	no backend-only critical feature remains hidden

### 13.4 Hidden Developer Mode

The application includes a hidden **Developer menu** intended for advanced users and debugging.

This menu must remain hidden during normal use.

Activation:
- The menu becomes visible when the user holds the **Option (⌥) key** while opening the menu bar.
- When the Option key is released, the menu disappears again.

Developer menu features:
- full container/service logs
- supervisor logs
- VM diagnostics
- RPC inspection
- container namespace information
- image cache inspection
- snapshot storage inspection
- port mapping table
- manual GC triggers
- export full diagnostics bundle

Design rules:
- developer mode must never clutter the consumer UI
- all developer tools live behind the Option-key menu
- no developer-only state should affect normal runtime behavior

The developer menu should open a dedicated **Diagnostics / Debug panel** exposing:

- VM state
- container runtime status
- supervisor health
- event stream
- structured logs

⸻

14. Build security controls and hardening

14.1 Trust model

Define trust states:
	•	signed and trusted publisher
	•	signed but untrusted publisher
	•	unsigned developer mode
	•	tampered

14.2 Capability prompts

Manifest-declared capabilities should be shown before first run:
	•	network access
	•	host file import
	•	port exposure
	•	background execution
	•	large disk usage

14.3 Runtime hardening

For containers:
	•	drop capabilities by default
	•	read-only root filesystem where possible
	•	no host PID namespace
	•	no privileged containers in v1
	•	limit writable mounts

14.4 Secret handling

Applications frequently require credentials such as:

- OPENAI_API_KEY
- AWS_SECRET_ACCESS_KEY
- API tokens
- database credentials

Secrets must **never be stored directly inside the immutable package contents**.

The system supports two secure mechanisms for secrets.

#### Method A — User-provided secrets (recommended default)

The `.vibeapp` manifest may declare required secrets:

```
secrets:
  - name: OPENAI_API_KEY
    required: true
  - name: AWS_SECRET_ACCESS_KEY
    required: false
```

When a user opens the app for the first time:

1. The host app detects missing secrets.
2. The user is prompted to enter them.
3. Secrets are stored in the **macOS Keychain**.
4. The runtime injects them as environment variables when services start.

Properties:

- secrets never exist inside the package
- secrets persist across project restarts
- secrets are scoped per project instance

#### Method B — Encrypted secrets inside the package

For some distribution models, developers may ship encrypted secrets bundled with the app.

In this case the `.vibeapp` package may contain an encrypted section:

```
secrets.encrypted
```

This blob contains:

- encrypted secret values
- encryption metadata
- key derivation parameters

When opening such an app:

1. The user is prompted for a **decryption password**.
2. The host decrypts the secrets in memory.
3. The secrets are injected into the runtime environment.

Security requirements:

- encryption must use a modern authenticated cipher (AES-GCM or ChaCha20-Poly1305)
- password derivation must use Argon2id or scrypt
- decryption attempts must implement **brute-force protection**:
  - exponential backoff after failed attempts
  - temporary lock after repeated failures

Decrypted secrets must never be written back to disk in plaintext.

#### Runtime injection

Regardless of storage method, secrets are provided to services via:

- environment variables
- optional mounted secret files

Secrets must be isolated per project instance and must not leak between apps.

Acceptance:

- secrets never appear in logs
- secrets never appear in snapshots
- secrets are not stored in the immutable package
- Keychain-backed secrets survive app restarts

⸻

15. Build resource control and garbage collection

15.1 Quotas

Per project:
	•	CPU shares/limits
	•	memory limit
	•	state size soft limit
	•	snapshot retention
	•	max exposed ports

15.2 GC

Periodic jobs:
	•	unused images
	•	orphan networks
	•	stopped containers
	•	stale temp files
	•	expired snapshots by retention policy
	•	unreachable chunks in snapshot store

15.3 Backpressure

When disk low:
	•	pause new imports
	•	warn user
	•	require cleanup before continuing heavy operations

Acceptance:
	•	long-running use does not leak resources
	•	deleting a project reclaims its namespace-scoped assets

⸻

16. Build the testing matrix before launch

You need four test layers.

16.1 Unit tests

For:
	•	manifest validation
	•	signature verification
	•	path normalization
	•	state index mutation
	•	snapshot metadata
	•	port allocation
	•	compose import

16.2 Integration tests

For:
	•	boot VM
	•	connect supervisor
	•	open package
	•	start web app
	•	start app + Postgres
	•	save/restore
	•	duplicate
	•	upgrade
	•	delete

16.3 Soak tests

Run for hours:
	•	repeated open/save/restore cycles
	•	concurrent projects
	•	image pull storms
	•	forced VM restarts
	•	host app relaunch

16.4 Failure injection

Simulate:
	•	disk full
	•	image pull timeout
	•	corrupted snapshot metadata
	•	crashed service during save
	•	abrupt host termination
	•	abrupt VM termination

Acceptance:
	•	every major flow has happy-path and failure-path tests
	•	no release without full integration suite pass

⸻

17. Build the release pipeline

17.1 Versioning

Version separately:
	•	host app
	•	VM image
	•	supervisor
	•	manifest schema
	•	snapshot schema

17.2 Upgrade path

Host upgrades must handle:
	•	old VM image migration
	•	old snapshot schema migration
	•	app project registry migration

17.3 Signing and notarization

Set up:
	•	app signing
	•	notarization
	•	entitlements
	•	CI release promotion
	•	rollback build retention

Acceptance:
	•	clean install works
	•	upgrade from previous release works
	•	rollback to previous release does not strand user data

⸻

18. Recommended implementation order

This is the exact order I would use.

Milestone 1: skeleton
	•	repo
	•	CI
	•	manifest schema
	•	package/sign/verify CLI
	•	dummy host app
	•	dummy supervisor

Milestone 2: VM boot
	•	Linux VM boot from host
	•	vsock RPC
	•	supervisor hello endpoint
	•	health check

Milestone 3: single-container app
	•	native manifest
	•	package import
	•	one service
	•	logs
	•	stop/start
	•	fixed port mapping

Milestone 4: multi-service app
	•	dependency ordering
	•	project networks
	•	named volumes
	•	web + Postgres reference app

Milestone 5: snapshots
	•	manual save
	•	list snapshots
	•	restore
	•	duplicate
	•	SQLite support

Milestone 6: Postgres correctness
	•	logical dump save hook
	•	restore validation
	•	health checks

Milestone 7: Compose import
	•	parse/import/validate Compose subset
	•	fixture suite
	•	import report UI

Milestone 8: UX and hardening
	•	trust UI
	•	capability prompts
	•	diagnostics
	•	quotas
	•	GC
	•	autosave

Milestone 9: release candidate
	•	installer
	•	signing
	•	migration tests
	•	soak tests
	•	docs

⸻

19. The seven hardest engineering problems and how to implement around them

1. VM boot latency

Do not boot on demand for every open.
Implement one warm VM and preflight it at app launch. Keep a health heartbeat and auto-recover when unhealthy.

2. Compose path semantics

Compose paths assume the daemon host. Since your daemon lives in Linux VM, rewrite all bind semantics to VM-local imported paths. Docker-style path assumptions do not map directly to macOS host paths once the daemon is inside the VM.  ￼

3. Snapshot correctness

A “copy files and hope” approach will corrupt DB-backed apps. Make save hooks explicit per consistency type and block concurrent writes during save.

4. Resource contention

One VM means one shared memory pool. Add project-level quotas early, not later.

5. State growth

Snapshots will explode in size unless chunk-deduplicated from day one. Build chunk store before launching autosave broadly.

6. Upgrade safety

Package format, state schema, and VM image all evolve independently. Build versioned migration handlers now.

7. Observability

Without event logs and diagnostics, every customer issue becomes unreproducible. Make every subsystem emit structured events from the start.

⸻

20. Definition of done for v1

You are done when all of this is true:
	•	a signed .vibeapp can be opened from Finder into the app
	•	the host verifies trust and shows capabilities
	•	the VM boots automatically if needed
	•	the supervisor imports the project
	•	a multi-service app can run in its own namespace
	•	logs stream into the UI
	•	the app can be stopped, restarted, duplicated, saved, restored
	•	SQLite and Postgres state survive restart and restore
	•	multiple apps run simultaneously without collision
	•	package upgrades create rollback points
	•	corrupted packages are rejected
	•	low-disk and crash scenarios are recoverable
	•	the app is signed, notarized, and upgradable

That is the path from zero to a complete first implementation.
