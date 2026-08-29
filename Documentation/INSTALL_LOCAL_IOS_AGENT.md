# Codex Task: Install and Validate a Fully Local iOS Coding Agent

## Objective

Set up this Mac as a fully working, payment-free, local iOS development agent using:

- Xcode
- Ollama
- `qwen3.5:9b`
- OpenCode stable
- XcodeBuildMCP CLI
- a project-level iOS/Swift `AGENTS.md`

The target machine is an Apple Silicon MacBook Pro with an M1 Pro, 16 GB unified memory, and a 512 GB SSD.

The final agent must use the local Ollama model. Do not configure a paid API, cloud model, trial subscription, or remote fallback. Keep Ollama bound to localhost and disable Ollama Cloud features after the local model has been downloaded.

Communicate with the user in Uzbek. Continue autonomously through all safe installation, configuration, and validation steps. Ask the user only when macOS requires a password, Xcode/App Store interaction, license acceptance, or when the iOS project path cannot be discovered safely.

## Completion Standard

Do not declare this task complete until all applicable checks pass:

1. Xcode and command-line tools are functional.
2. Ollama is running on `127.0.0.1:11434`.
3. `qwen3.5:9b` is downloaded locally.
4. A 64K-context iOS model variant is created and responds successfully, or a documented 32K fallback is used only after the 64K configuration fails because of memory pressure.
5. Ollama Cloud is disabled and no remote model/API is configured.
6. Stable OpenCode is installed and selects the exact local Ollama model.
7. XcodeBuildMCP CLI is installed and `doctor`/tool discovery succeeds.
8. The XcodeBuildMCP CLI skill is available to OpenCode.
9. The iOS/Swift `AGENTS.md` is present at the project root and OpenCode proves that it loaded the instructions.
10. If an iOS project is available, its real scheme builds for Simulator and relevant tests run successfully.
11. A final setup report records versions, configuration, verification results, and any remaining manual action.

## Safety and Idempotency

- Begin with read-only discovery.
- Reuse valid existing installations instead of reinstalling them.
- Do not overwrite existing OpenCode, Ollama, shell, Git, XcodeBuildMCP, or `AGENTS.md` configuration blindly.
- Read existing files first, merge the smallest necessary changes, and preserve unrelated settings.
- Before changing a user configuration file, create a clearly named timestamped backup next to that file when practical.
- Never delete an existing model, project, simulator, certificate, provisioning profile, Derived Data directory, or user configuration as part of setup.
- Do not modify bundle identifiers, signing teams, entitlements, deployment targets, or dependency versions merely to make the smoke test pass.
- Do not use `sudo` except when the official Homebrew or Xcode setup genuinely requires it. Let the user enter credentials; never request or capture their password.
- Do not expose the Ollama server on `0.0.0.0` or the local network.
- Do not commit generated setup files unless the user explicitly asks.
- Keep a concise log of commands, versions, and outcomes for the final report. Do not record secrets or device identifiers.

## Phase 1: Resolve the iOS Project

1. Inspect the current directory and parent Git root.
2. Search with focused commands for:
   - `*.xcworkspace`
   - `*.xcodeproj`
   - `Package.swift`
   - an existing `AGENTS.md`
3. If exactly one plausible iOS project is found, use its Git root as `PROJECT_ROOT`.
4. If multiple projects are found, ask the user which project to configure.
5. If no project is found, proceed with global tool installation and validation, then ask for the project path before project-specific integration.
6. Resolve `PROJECT_ROOT` to an explicit absolute path. Do not use an unresolved environment variable in destructive or write operations.

## Phase 2: Preflight the Mac

Collect and record:

```bash
uname -m
sw_vers
sysctl -n hw.memsize
df -h /
xcode-select -p
xcodebuild -version
swift --version
git --version
```

Expected architecture is `arm64`. Warn the user if less than 20 GB of disk space is free because model files, build artifacts, Simulator runtimes, and caches need working space.

### Xcode requirements

- Require macOS 14.5 or newer and Xcode 16 or newer for XcodeBuildMCP.
- If Xcode is missing, ask the user to install the current compatible Xcode from the Mac App Store or Apple Developer downloads.
- If command-line tools are missing, run `xcode-select --install` and let the user complete the macOS dialog.
- If multiple Xcode installations exist, inspect them and use the user's intended stable Xcode. Do not switch the global developer directory without explaining the change.
- If the Xcode license or first-launch components block commands, show the exact Apple command/dialog required and let the user approve it.

Do not continue to XcodeBuildMCP validation until `xcodebuild -version` and `swift --version` succeed.

## Phase 3: Install or Validate Homebrew

Check:

```bash
command -v brew
brew --version
```

If Homebrew is missing, use the official installer from `brew.sh`. Do not use a third-party package mirror. After installation, apply the `brew shellenv` line appropriate for Apple Silicon only if required. Preserve existing shell configuration and avoid adding duplicate lines.

Then run:

```bash
brew update
brew doctor
```

Report meaningful warnings, but do not attempt unrelated cleanup.

## Phase 4: Install and Configure Ollama

### Install

If Ollama is not installed:

```bash
brew install --cask ollama
```

Start the native macOS app:

```bash
open -a Ollama
```

Poll the localhost endpoint with a bounded timeout until it responds:

```bash
curl -fsS http://127.0.0.1:11434/api/tags
```

Confirm the listener is local-only. Do not change `OLLAMA_HOST` to a network address.

### Download the exact local model

```bash
ollama pull qwen3.5:9b
ollama list
```

Confirm that `qwen3.5:9b` exists locally. Its normal Ollama Q4 download is approximately 6.6 GB.

### Configure for 16 GB unified memory and local-only operation

Set these macOS application environment variables with `launchctl`:

```bash
launchctl setenv OLLAMA_NO_CLOUD "1"
launchctl setenv OLLAMA_FLASH_ATTENTION "1"
launchctl setenv OLLAMA_KV_CACHE_TYPE "q8_0"
launchctl setenv OLLAMA_NUM_PARALLEL "1"
launchctl setenv OLLAMA_MAX_LOADED_MODELS "1"
```

Rationale:

- `OLLAMA_NO_CLOUD=1` disables Ollama Cloud features.
- Flash Attention reduces memory usage as context grows when supported.
- `q8_0` K/V cache uses roughly half the memory of the default `f16` cache with a small quality trade-off.
- One parallel request and one loaded model prevent context memory from multiplying on a 16 GB machine.

Restart the Ollama app cleanly after changing the environment. Recheck the localhost endpoint. Do not expose it externally.

### Create a 64K model variant

Create a temporary Modelfile using a safe file-editing method, not an unsafe shell interpolation. The exact content is:

```text
FROM qwen3.5:9b
PARAMETER num_ctx 65536
```

Create the local variant:

```bash
ollama create qwen3.5-ios:9b-64k -f /absolute/path/to/the/Modelfile
```

Verify metadata and perform a direct one-shot response test:

```bash
ollama show qwen3.5-ios:9b-64k
ollama run qwen3.5-ios:9b-64k "Reply with exactly: OLLAMA_LOCAL_OK"
ollama ps
```

Require the expected response. Confirm the model is using Apple Silicon acceleration as reported by `ollama ps` and that no cloud model is selected.

### 32K fallback policy

OpenCode officially recommends 64K or more. Do not choose 32K merely for convenience.

If the 64K model fails to load because of verified out-of-memory pressure even with Flash Attention, `q8_0` K/V cache, one model, and one parallel request:

1. Record the exact failure.
2. Create a fallback variant with:

```text
FROM qwen3.5:9b
PARAMETER num_ctx 32768
```

3. Name it `qwen3.5-ios:9b-32k`.
4. Repeat the direct response test.
5. Clearly record that long OpenCode sessions may be less reliable and should be restarted more frequently.

Do not silently substitute `qwen3.5:4b`, a cloud model, or another model.

## Phase 5: Install and Configure Stable OpenCode

Install the stable OpenCode release using the official installer if `opencode` is absent:

```bash
curl -fsSL https://opencode.ai/install | bash
```

Do not install the OpenCode v2 beta unless the user explicitly requests it. Make sure the stable binary is on the current and future shell `PATH` without duplicating profile entries.

Verify:

```bash
opencode --version
opencode --help
```

### Connect the local Ollama model

First let Ollama generate the supported OpenCode configuration for the installed versions:

```bash
ollama launch opencode --model qwen3.5-ios:9b-64k --config
```

If the 32K fallback was required, use `qwen3.5-ios:9b-32k` instead.

Then verify the exact provider/model identifier from OpenCode rather than guessing:

```bash
opencode models
```

The selected provider must be local Ollama, normally:

```text
ollama/qwen3.5-ios:9b-64k
```

Set that exact discovered identifier as the OpenCode default using the configuration format supported by the installed stable version. Prefer the generated configuration. If manual editing is required:

1. Locate the active OpenCode configuration with its own diagnostics/help.
2. Read and back up the existing file.
3. Merge only the local model/default-model setting.
4. Validate the file against `https://opencode.ai/config.json` or the installed version's configuration command.
5. Preserve unrelated providers, permissions, plugins, commands, and user preferences.

Do not insert API keys or configure remote providers.

### OpenCode local inference smoke test

Use the exact local model ID shown by `opencode models`:

```bash
opencode run --model ollama/qwen3.5-ios:9b-64k "Reply with exactly: OPENCODE_LOCAL_OK"
```

Use the 32K ID only if that documented fallback was activated. Require the exact response and confirm that Ollama shows the local model running during the test.

## Phase 6: Install and Configure XcodeBuildMCP CLI

Install through its official Homebrew tap if absent:

```bash
brew tap getsentry/xcodebuildmcp
brew install xcodebuildmcp
```

Verify:

```bash
xcodebuildmcp --help
xcodebuildmcp tools
xcodebuildmcp doctor
```

XcodeBuildMCP includes optional Sentry runtime-error telemetry. For a local/private setup, disable it for new GUI processes and the current setup session:

```bash
launchctl setenv XCODEBUILDMCP_SENTRY_DISABLED "true"
export XCODEBUILDMCP_SENTRY_DISABLED="true"
```

Do not rewrite shell startup files solely for this variable without the user's approval. The project `AGENTS.md` should remind the agent to preserve this environment setting when invoking the CLI.

### Install the CLI skill for OpenCode

XcodeBuildMCP's automatic `init` supports Codex, Claude Code, and Cursor directly. For OpenCode, create a project skill explicitly:

```text
PROJECT_ROOT/.opencode/skills/xcodebuildmcp-cli/SKILL.md
```

Obtain the official current skill body with:

```bash
xcodebuildmcp init --print --skill cli
```

Save that exact output into the `SKILL.md` path using a safe file-editing method. Ensure the YAML frontmatter contains a clear description and a lowercase hyphenated name matching the directory (`xcodebuildmcp-cli`) if the printed skill uses a different client-specific name. Preserve the official body and command conventions.

Verify that OpenCode discovers the skill using the installed version's skill listing or an OpenCode prompt that lists available project skills. Do not assume discovery without testing it.

## Phase 7: Install the iOS/Swift `AGENTS.md`

Place the supplied iOS `AGENTS.md` at:

```text
PROJECT_ROOT/AGENTS.md
```

If an `AGENTS.md` already exists:

1. Read it completely.
2. Preserve its project-specific rules.
3. Merge the supplied iOS/Swift guidance without duplicating or contradicting existing instructions.
4. Keep the final file concise enough for agent instruction limits.

At minimum, the resulting file must require:

- senior production iOS engineering behavior;
- communication with the user in Uzbek;
- Swift 6 and strict-concurrency-safe code;
- SwiftUI for new UI unless the existing project requires UIKit;
- `Sendable`, actors, structured concurrency, and correct `@MainActor` boundaries;
- no production force unwraps, hidden singletons, swallowed errors, or secrets in source/logs;
- deterministic Swift Testing/XCTest coverage appropriate to risk;
- XcodeBuildMCP CLI for project discovery, build, test, Simulator, logs, and UI verification;
- one Simulator at a time on the 16 GB Mac;
- preservation of user changes and no destructive Git operations;
- a definition of done that requires successful build/test and honest reporting of anything unverified.

The OpenAI Codex documentation and OpenCode both support project-level `AGENTS.md` guidance. Keep the file at the real project root so both tools can use the same engineering rules.

### Prove that OpenCode loaded the instructions

From `PROJECT_ROOT`, run a read-only prompt using the exact local model:

```bash
opencode run --model ollama/qwen3.5-ios:9b-64k "Without changing files, summarize the current project instructions: your role, response language, Swift concurrency policy, required Xcode tool, and definition of done."
```

The response must mention:

- senior iOS/Swift engineering;
- Uzbek communication;
- Swift 6/strict concurrency;
- XcodeBuildMCP CLI;
- build/test verification before completion.

If it does not, diagnose instruction discovery and fix the project root or file placement before continuing.

## Phase 8: Configure XcodeBuildMCP for the Real Project

Run from `PROJECT_ROOT`:

```bash
xcodebuildmcp setup
```

Infer selections from the real project where possible:

- platform: iOS;
- actual `.xcworkspace` preferred over `.xcodeproj` when both exist and the workspace is authoritative;
- real shared/buildable scheme;
- Debug configuration for smoke testing;
- one installed iPhone Simulator compatible with the deployment target;
- simulator workflow enabled;
- Swift Package workflow when relevant;
- UI automation and debugging only when useful to the project.

The wizard creates or updates `.xcodebuildmcp/config.yaml`. Read existing configuration first, preserve valid project settings, and do not commit it without the user's permission.

After setup:

```bash
xcodebuildmcp doctor
xcodebuildmcp tools
```

Use `xcodebuildmcp --help` and focused subcommand help to discover exact flags for the installed version. Do not invent scheme, destination, project, workspace, or simulator values.

## Phase 9: End-to-End iOS Smoke Test

If a real iOS project is available:

1. Inspect Git status and do not alter unrelated work.
2. Discover the actual project/workspace, schemes, and installed compatible simulators.
3. Use XcodeBuildMCP CLI to build the selected scheme for Simulator.
4. Run relevant unit tests. If no tests exist, say so instead of fabricating success.
5. Build and run the app on one Simulator when feasible.
6. Capture and inspect runtime logs for immediate crashes or configuration failures.
7. Perform a read-only OpenCode task asking the local agent to summarize the project and the last build result. Do not ask it to modify production files merely for setup validation.
8. Confirm that `ollama ps` shows the expected local model during agent execution.

If the build fails because of existing project code, report the exact existing failure separately. Do not make broad application-code changes unless the user asks to fix the project.

If no iOS project is available, validate XcodeBuildMCP with `doctor`, tool discovery, Xcode detection, and Simulator discovery, then mark only the project build phase as pending and ask for the project path.

## Phase 10: Final Report and Daily Usage

Create a concise Markdown report named `LOCAL_IOS_AGENT_SETUP_REPORT.md` in `PROJECT_ROOT` when a project exists; otherwise save it in the current working directory.

Include:

- Mac architecture, macOS version, and available memory/disk summary;
- Xcode, Swift, Homebrew, Ollama, OpenCode, and XcodeBuildMCP versions;
- installed Ollama model names and selected context size;
- whether Flash Attention, `q8_0` K/V cache, single parallel request, and local-only mode are active;
- confirmation that the Ollama listener is localhost-only;
- exact OpenCode model identifier;
- OpenCode local-response test result;
- XcodeBuildMCP `doctor` result;
- OpenCode skill discovery result;
- `AGENTS.md` instruction-discovery result;
- project scheme, Simulator, build result, test result, and runtime result when applicable;
- any manual step or limitation still pending.

Give the user these normal start commands using the exact installed model/configuration:

```bash
open -a Ollama
cd /absolute/path/to/PROJECT_ROOT
opencode
```

If the stable OpenCode configuration did not persist the model selection reliably, use the official launcher instead:

```bash
cd /absolute/path/to/PROJECT_ROOT
ollama launch opencode --model qwen3.5-ios:9b-64k
```

Also explain how to release memory after work:

```bash
ollama stop qwen3.5-ios:9b-64k
```

Use the 32K model name only if the documented fallback was actually required.

## Failure Handling

- Do not loop indefinitely. Use bounded retries and inspect logs between attempts.
- If Ollama fails, check the app state, localhost port, logs, model metadata, and memory settings.
- If OpenCode cannot see the model, verify Ollama's native model list, restart OpenCode, inspect the installed OpenCode version's provider diagnostics, and use `ollama launch opencode --config`.
- If tool calls degrade after several messages, verify the effective context size and begin a fresh session rather than silently switching to a cloud model.
- If XcodeBuildMCP fails, run `xcodebuildmcp doctor`, verify Xcode selection/version, and inspect focused help/troubleshooting output.
- If Simulator build fails, distinguish environment/setup errors from existing application-code errors.
- Stop and request user action only when credentials, App Store access, license acceptance, a project choice, or a material change in scope is required.

## Authoritative References

- Codex `AGENTS.md`: https://developers.openai.com/codex/agent-configuration/agents-md
- Ollama and OpenCode: https://docs.ollama.com/integrations/opencode
- Ollama local-only/context/memory settings: https://docs.ollama.com/faq
- Qwen3.5 model library: https://ollama.com/library/qwen3.5
- OpenCode models and Ollama discovery: https://opencode.ai/v2/docs/models
- OpenCode skills: https://opencode.ai/v2/docs/skills
- XcodeBuildMCP: https://www.xcodebuildmcp.com/docs
- XcodeBuildMCP setup: https://www.xcodebuildmcp.com/docs/setup
- XcodeBuildMCP skills: https://www.xcodebuildmcp.com/docs/skills

Before executing, check these official pages for breaking changes in commands or configuration. Prefer the installed tool's `--help` and official current documentation over stale examples in this file if they conflict, but preserve the required local model and no-paid-API constraint.
