# Local iOS Agent

Native macOS SwiftUI application for running a local iOS coding agent without showing a Terminal window.

The application launches OpenCode as a background process, uses a local Ollama model, parses OpenCode's JSONL event stream, and provides quick actions for XcodeBuildMCP-based analysis, build, test, and Simulator workflows. OpenCode session IDs and the local transcript are persisted so a later app launch can resume the same agent context.

The built-in Dependency Center performs typed, parallel diagnostics before a task starts. It verifies the selected Ollama model and context metadata, OpenCode's executable/version/model catalog, XcodeBuildMCP's current tool catalog, plus the selected project's Xcode/Swift build artifacts and agent instruction files. When a supported project is selected, the app safely installs missing `AGENTS.md` and OpenCode XcodeBuildMCP skill files without overwriting existing project instructions.

## Supported system

- Apple Silicon Mac
- macOS 14 or newer
- Xcode 16 or newer
- Swift 6 toolchain

The Swift package has no third-party source dependencies.

Runtime tools expected on the target Mac:

- Ollama at `127.0.0.1:11434`
- OpenCode available as `opencode`
- XcodeBuildMCP CLI available as `xcodebuildmcp`
- Local model `ollama/qwen3.5-ios:9b-64k`

## Project structure

```text
Package.swift
Sources/LocalIOSAgent/
  AgentController.swift
  ContentView.swift
  DependencyDiagnostics.swift
  LocalIOSAgentApp.swift
  Models.swift
  OpenCodeClient.swift
  ProcessModels.swift
  OutputSanitizer.swift
  ProjectBootstrapper.swift
  ProcessRunner.swift
  SessionStore.swift
Tests/LocalIOSAgentTests/
  AgentControllerTests.swift
  DependencyDiagnosticsTests.swift
  OpenCodeClientTests.swift
  OutputSanitizerTests.swift
  ProjectBootstrapperTests.swift
  ProcessRunnerTests.swift
  SessionStoreTests.swift
scripts/
  package_app.sh
```

## Build and test

Open `Package.swift` with Xcode, or run:

```bash
swift test
swift build -c release
```

To create a standalone `.app` bundle:

```bash
./scripts/package_app.sh
```

The result is written to:

```text
dist/Local iOS Agent.app
```

The packaging script creates an ad-hoc signed application. For distribution outside your own Macs, add a Developer ID signature and Apple notarization.

## Sessions and OpenCode integration

- A new turn runs `opencode run --format json` and reads typed `step_start`, `text`, `tool_use`, `step_finish`, and `error` events.
- Once OpenCode reports its session ID, subsequent turns use `--session <id>` to preserve the real agent context.
- The UI stores up to 50 local session transcripts in `~/Library/Application Support/LocalIOSAgent/sessions-v1.json` using an atomic, versioned JSON archive.
- A corrupt or unsupported archive is reported to the user and is never overwritten while loading.
- Some OpenCode versions can exit successfully without emitting a final text event. The app treats this as a visible “no response” state instead of reporting false success.

## Dependency Center and project preflight

- Ollama diagnostics call the local `/api/tags` and `/api/show` contracts to prove that the configured model is installed and report its context length, parameter size, and quantization.
- CLI probes record executable paths and versions. OpenCode's model catalog must include the configured provider/model before agent submission is enabled.
- XcodeBuildMCP readiness uses the current `--version` and `tools` contracts. The removed `doctor` command is never invoked.
- Project preflight detects `.xcworkspace`, `.xcodeproj`, or `Package.swift`, prefers a workspace, and reports whether Git, `AGENTS.md`, and an XcodeBuildMCP project skill are present.
- Missing `AGENTS.md` and `.opencode/skills/xcodebuildmcp-cli/SKILL.md` files are installed automatically from bundled templates. Existing files are preserved byte-for-byte, unsupported folders are not modified, and symbolic-link destinations are rejected.
- Diagnostics use injectable `Sendable` protocols, parallel structured concurrency, stale-result protection in the `@MainActor` controller, explicit timeouts, and bounded output collection.

## Use on another Mac

1. Install the runtime stack using `Documentation/INSTALL_LOCAL_IOS_AGENT.md`.
2. Build the app using the commands above, or use the included prebuilt app on a compatible Apple Silicon Mac.
3. Start Ollama and choose an iOS project folder. The app adds missing project agent files automatically.
4. Enter a task in the application.

## Privacy and safety

- The application sets `OLLAMA_NO_CLOUD=1` for child processes and connects to Ollama through localhost.
- Child processes disable automatic OpenCode sharing and do not inherit common remote-model API-key variables.
- Process output is streamed through a bounded buffer; collection commands also use explicit byte limits and timeouts.
- OpenCode JSON lines are bounded to 8 MB, and completed text/tool parts are de-duplicated by part ID.
- Cancellation targets the process tree and escalates from `SIGINT` to `SIGTERM` and `SIGKILL` only when required.
- No API key is embedded in the source code.
- OpenCode can modify project files and run local commands. Keep projects under version control and review changes before committing.
