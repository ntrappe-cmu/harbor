# Harbor

A minimal native macOS app for running Claude Code and Codex on a copied project inside a local Apple container VM. Harbor provides a task-and-follow-up interface, resource limits, a local browser preview, activity logs, and Keychain-backed provider credentials.

This is an early development MVP, not a production security product.

## Requirements

- Apple silicon Mac running macOS 26 or later.
- Xcode with Swift 6 tooling. The build script currently uses `/Applications/Xcode.app/Contents/Developer`.
- [Apple container 1.5.x](https://github.com/apple/container/releases/tag/1.5.0), with its recommended Linux kernel configured.
- Separately billed Claude or OpenAI API keys for assistant tasks. Preview-only use requires no provider key.

## Build and run

```bash
bash scripts/build.sh
open dist/Harbor.app
```

In Settings, prepare the local workspace tools and set the assistant's API key. Preparation builds the `harbor-agents:v3` image and downloads pinned Claude Code and Codex CLI versions. Import a folder or use a starter project, choose limits, and start a task. Preparation can interrupt its build command without stopping the shared Apple runtime.

## Features

- Per-workspace CPU and memory limits, run allowance, and performance presets.
- Copied working files, checkpoints, and export of completed work.
- Read-only working-folder option, restricted Linux capabilities, network-off option, and localhost preview publishing.
- Separate frozen submitted prompts and persistent unsent drafts. Follow-ups are sent manually; full workspace shutdown ends the provider conversation.
- Task-only cancellation and full workspace stop.
- Resource measurements, file-type/storage summaries, and repeated activity messages with count badges.
- Provider credentials in macOS login Keychain. Drafts and metadata are stored locally under `~/Library/Application Support/Harbor/Workspaces`; drafts use the hidden `.drafts` directory.

## Current limits

- Isolation is not proof that generated code is safe and does not reliably detect VM escape attempts.
- Allowed network access is unrestricted outgoing access, not a destination allowlist. Prompts and relevant files can be sent to the selected cloud provider; guest tools can access the provider key during a run.
- Storage thresholds are warnings, not quotas. Time control is operational rather than tamper-proof.
- The usage meter defaults to a **simulated $40 balance**, not your provider account balance. Actual provider reporting can be incomplete, and spending is not capped.
- Builds are ad-hoc signed and not notarized. Stable signing, distribution, and complete accessibility/HIG review remain open.
- Raw assistant output is bounded and held in memory. Drafts and summary/history metadata are local plaintext, not Keychain items.

## Tests

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
swift test --disable-sandbox
```

The current suite has 50 tests. Tests use synthetic credentials and runtime fixtures. An optional local smoke check, `python3 scripts/verify-access-policies.py`, creates temporary Apple containers to check mount and capability enforcement, then removes them. It uses no provider keys or paid requests.

See [VERIFICATION.md](VERIFICATION.md) for dated evidence and outstanding checks, [STORAGE-DESIGN.md](STORAGE-DESIGN.md) for storage design, and [USABILITY-REVIEW.md](USABILITY-REVIEW.md) for the initial synthetic usability review.
