# Harbor verification — 2026-10-05

## Tested environment

- Apple silicon Mac, macOS 26.6.2, Apple container 1.5.0.
- Apple-recommended Linux kernel was already configured. Repeating `kernel set --recommended` failed because the downloaded file existed; the existing default kernel successfully ran every smoke workload. No replacement kernel was installed.
- Image: `harbor-agents:v2`; tested Claude Code 2.1.289 and Codex CLI 0.160.0. These CLI versions are now pinned in the build recipe.
- No real provider API request or billing was exercised.

## Real runtime checks

Disposable containers were removed after verification. Only their temporary folders were modified.

- Localhost preview returned the expected static file on a selected host port.
- Guest wrote to its working folder; the file survived stop and deletion of the container.
- JSON stats returned CPU time, memory use/limit, and process count. One idle sample reported 115,179,520 bytes used against a 2,147,483,648-byte limit and 11 processes.
- Offline container had only `lo`; no network interface to an external network.
- Guest deadline stopped the container without relying on the GUI timer.
- Configured 2 CPUs: `cpu.max` was `200000 100000` (two cores of CPU quota). Guest-visible CPU count was 3 because the runtime adds an overhead CPU. Meters normalize by the configured workload quota, not guest-visible cores.
- Configured 2 GiB: `memory.max` was `2147483648`.

## Automated coverage

Core tests cover import/export boundaries, oversized imports, checkpoint restore, settings migration, deletion/recovery, storage classification, invalid configurations, offline/preview arguments, unknown runtime schemas, CPU sampling, provider usage/error events, pipe output, cancellation and timeout.

App lifecycle tests use a fake runtime, never provider credentials. They cover blocked/corrupt storage, save failure before launch, stop during startup, unconfirmed stop preventing deletion, provider failure with exit code zero, persistent redacted problems, unexpected VM exit, and concurrent deadline extensions.

## Settings and measurement semantics

- CPU, memory, network and preview port changes take effect at the next start. The UI locks these during a run; the adapter validates saved values again.
- Internet off removes the guest network. Cloud assistants and browser preview are unavailable in this mode.
- Preview toggles control localhost port publishing. They are not a network firewall; guest services can still be reachable through the runtime virtual network when networking is enabled.
- Duration uses the same absolute deadline in the GUI and guest. It can be extended during a run. This is operational control, not tamper-proof enforcement against guest code.
- Storage threshold is a warning, not a disk quota. Measurements cover logical working-file sizes, excluding runtime images, snapshots, and symlinks. Scans stop after 100,000 entries and mark results partial.
- Runtime polling is serial, approximately every five seconds. Working-file scans run approximately every 30 seconds for the selected workspace. Missing/stale samples are not shown as zero.
- Provider token counts and cost are displayed only when reported. They are not enforced caps or a complete billing ledger; cache usage and unfinished requests may be absent.
- Recent redacted problems and activity summaries persist with workspace metadata. Raw assistant output remains bounded and in memory; full conversation persistence is separate work.

## UI verification and limits

The rebuilt application was launched using a separate UI-QA data root. Its native form snapshot was inspected; a duplicated slider label was found and removed. A retry confirmed the grey starter bar and identified resource sections pushing task input below the fold; those sections were moved below task controls. The in-process snapshot does not capture composited sidebar/title regions reliably. Full visual/accessibility/keyboard/swipe verification remains open; no claim of complete HIG compliance.

Real invalid-key, provider connectivity and rate-limit behavior still needs an API-backed run. Failure fixtures exercise the app logic but do not substitute for provider testing. Disk-write failure is injected rather than filling the user’s disk. Arbitrary OS termination and forced hardware shutdown have not been tested. Guest isolation does not prove generated code safe.

## Keychain credentials — 2026-10-05

- Provider keys are generic-password items in the macOS login Keychain, scoped to Harbor’s service (`dev.harbor.workspace.api-keys`) and separate `codex`/`claude` accounts. Synchronization is disabled. Harbor does not create plaintext credential files.
- Set/replace uses a secure entry sheet with explicit Save; failed writes preserve the previous key. Removal clears the entry and cached value only after Keychain confirms success.
- Keychain work runs off the UI thread. Automatic retrieval is independent of runtime reconciliation. New tasks wait while their provider’s credential operation is in progress.
- Runtime keys remain available to guest tools. Removing an entry does not revoke the key at its provider or erase it from an already-running guest.
- Native save/read/replace/provider-isolation/delete passed using a unique synthetic test service. The item was cleaned up; user credentials were not read or modified.
- Automated tests cover reload across app models, exclusion from workspace metadata, failed replacement/removal, denied retrieval/retry, and input validation. Total: 27 passing tests.
- Development builds are ad-hoc signed. macOS may request Keychain access again after rebuilding; access across release updates requires a stable signing identity and verification. The synthetic probe verifies the adapter, not the final distributed app’s access-control identity.

## Prompt UI — 2026-10-05

The prompt uses a left-aligned multiline editor. During a run, it remains visible as a compact summary with native progress feedback while an assistant task is active. Edit Draft changes only the next-run draft; it cannot amend a submitted request. A regression test verifies the submitted prompt stays unchanged while the draft is edited and that task progress ends when the assistant exits. Total: 28 passing tests.

Run Task asks the assistant to edit the project. Open Project Preview starts and opens a local preview of existing files, without an assistant request. An active workspace must still be stopped before submitting a revised task; follow-ups and task-only cancellation remain separate work.

## Task section revision — 2026-10-05

Replaced the prompt field with an NSTextView-based editor with explicit left paragraph alignment and IME composition protection. In a running isolated test window, the form snapshot confirmed sample text starts on the left and wraps with a ragged right edge. The snapshot still cannot reliably show composited header/sidebar regions.

Overview’s Task section now contains assistant selection, input/current task summary, bounded local prompt history, Start Task, Preview Only, and Stop Workspace. Key entry is confined to Settings. Stop, restore, key removal, history clearing and workspace deletion use destructive roles, with explicit red text for the relevant visible controls.

The latest ten submitted prompts persist locally, with known credential values redacted and very long prompts marked truncated. Settings offers Clear Prompt History. Reused drafts require review and do not modify a submitted task. The existing draft regression test also verifies history survives persistence. All 28 tests pass.

## Re-run transitions — 2026-10-05

Start Task/Re-run Task can switch an existing preview or assistant workspace to a new task. Harbor validates the selected provider/key/prompt before stopping; confirmed stop and cleanup must complete before launching the explicit workspace ID again. Editing is disabled during the transition. A missing/deleted target does not fall back to a different selected workspace.

Cancel Task currently stops the full workspace, including preview, and preserves the draft and files. After cancellation the prompt editor is available and the task can be run again. Running-request modification is implemented as a stop-and-new-run operation, not provider request mutation or session resume.

Creation ownership is keyed by run token so an old execution’s deferred cleanup cannot clear a new run’s startup state. Regression tests cover preview-to-task, stop/edit/re-run and cleanup failure blocking a second launch. Total: 30 passing tests. Real provider-backed reruns remain to verify.

## Compact usage indicator — 5 October 2026

- Overview: compact assistant-adjacent monthly Harbor budget bar when reported final costs allow a remaining estimate; pending/unavailable states otherwise. Settings: per-assistant budgets, visibility, low-budget warnings, reported task costs/tokens, official billing links.
- Local usage.json is separate from workspace metadata; deleting a workspace does not delete its tracked spend. Streamed and transcript copies replace the same run report rather than double counting.
- No provider balance, token allowance, automatic model price inference, or enforced spending cap is claimed. Earlier tasks and other apps are excluded. Costs belong to the start month, and any still-active task for that assistant suppresses a remaining estimate.
- Interrupted tasks without confirmed final billing reports remain incomplete. Missing/corrupt/unwritable usage history suppresses remaining estimates; unreadable history is not overwritten.
- Core checks cover duplicate reports, incomplete/canceled costs, JSON roundtrip, provider/month scopes, cross-month active tasks, and over-budget clamping.
- Synthetic source-based walkthrough and read-only watcher findings are in USABILITY-REVIEW.md. These are hypotheses, not recruited-user observations.

## Approved usability changes — 5 October 2026

- All eleven review choices implemented: disabled-run reason, separate Stop Task / Stop Workspace, simulated shared $40 balance, monthly spending warning terminology, assistant session follow-ups, run-specific preview probing, recorded CPU allocation, previous-run issue grouping, directional bar labels, actual generated file-type breakdown, and known-minimum spending warnings.
- Demo mode defaults on and persists in usage.json. Each launched AI workload deducts a synthetic $0.50 + prompt bytes / 2000 estimate (maximum $5). It is independent of provider-reported costs, is not real credits, and can be disabled in Settings. Preview-only runs do not deduct a task estimate.
- Follow-ups resume the provider session ID only in the same running VM and selected assistant. Full stop clears sessions; prompt history remains. Before each follow-up, a checkpoint is taken. Resume dollar reports with unverified cumulative scope are excluded from actual cost aggregation.
- Task-only stopping uses a token-scoped guest process identity and inherited environment marker, verifies PID start time before signaling, drains tagged child processes including ordinary detached children, and leaves preview/deadline/VM running. This is operational cleanup, not a security boundary against a process that deliberately clears its marker. Full VM stop remains the complete workspace boundary.
- Cancellation before follow-up launch prevents execution, including while the checkpoint is pending. Unconfirmed stops block new tasks; absence of an unpublished process identity is not treated as successful stopping.
- Preview health: bounded localhost HEAD request, redirects disabled, expected run identity header, separate checking/available/missing-page/unavailable/unknown states. Image harbor-agents:v3 built locally.
- 40 Swift tests pass, including stop-task preservation, scoped session continuation, archived previous issues, changed starter-file detection, duplicate-safe demo costs, old ledger decoding, and cancellation during a gated checkpoint without agent launch.
- Disposable real Apple-container smoke passed preview identity, exact pinned Codex resume CLI argument parsing, Claude resume flag, cancellation of an ordinary detached child while preview survives, and natural-exit child cleanup. Evidence: .local-data/runtime-v3/verification.json. Test guest removed; zero paid AI requests.
- Native Overview screenshot checked: assistant-adjacent demo bar, left-aligned input, disabled-run explanation, Settings shortcut. No real provider authentication or paid end-to-end follow-up was tested.

## Prompt-flow separation — 5 October 2026

Submitted prompts are read-only. New-task and follow-up drafts use separate buffers with an explicit composer mode. Sending a follow-up clears only its captured draft; edits for subsequent prompts remain separate. Send Follow-up remains visible but disabled while the current task works or while its conversation is unavailable. Stopping the workspace never silently converts an unsent follow-up into a new task; an explicit Use Draft as New Task action is available. Per-task elapsed time freezes on completion/stop and is labeled as including preparation. Latest activity and explicit outcomes indicate progress without an invented percentage. All 40 tests pass; follow-up fixtures now verify independent buffers and restore a canceled prelaunch draft.

Follow-up draft preservation also covers full workspace stop during a pending checkpoint; regression suite now has 41 passing tests. Conversion to New Task asks before replacing an existing new-task draft. Latest task activity is captured separately from later workspace/export events; preparation and completion outcomes are explicit.

The harbor-usage-options visualization was repaired for host compatibility: optional controls do not block rendering, saved state is validated, state setters returning void or throwing are handled, and delayed markup initializes safely. All four designs plus Details, Hide/Show, and checkpoint dismissal were inspected in the local preview with no logged JavaScript errors. Five synthetic host-compatibility cases passed.

## Running prompt flow refinement

While a task is active, only its separate follow-up editor is offered; the New Task mode picker and history reuse action are unavailable until it settles. Submitted text remains read-only and Send Follow-up remains disabled with an explanation. Task history now persists optional elapsed seconds, outcome, and latest task activity per submitted prompt. Token and history-item identity guards prevent old task cleanup from updating a newer task. Finished first-task progress remains inspectable after a follow-up starts and after reopening Harbor. A later workspace stop failure does not relabel an already-finished assistant task as unfinished. Existing metadata decodes with absent optional fields. Lifecycle checks verify both original and follow-up progress survive the workspace-store roundtrip.

## 2026-10-05 — Persistent drafts and manual follow-up flow

- New Task text, unsent follow-up text, and selected draft type persist per workspace as atomic JSON snapshots under the hidden `Workspaces/.drafts` directory in Harbor’s app-data root (or the configured data root). Draft files use owner-only permissions; they are local plaintext, outside Project, checkpoints, and exports. API credentials remain in Keychain.
- While an assistant task is active, the submitted prompt remains read-only and the separate next-message editor remains available. Send and Preview Only controls are hidden during the task. Successfully saved nonempty drafts show “Draft saved · Not sent”; nothing is automatically sent when a task finishes.
- Idle tasks retain manual Send Follow-up, with existing session and stop-confirmation checks. Full workspace stop/reopen preserves unsent text without inventing a resumable conversation. The draft selector remains visible for restored Follow-up mode even when empty, allowing access to an existing New Task draft.
- Save failures show an error and Retry Saving Draft. Unreadable stored drafts are preserved rather than overwritten. Deleting a workspace also removes its draft snapshot; late callbacks cannot recreate a deleted workspace’s on-disk draft.
- Validation: 44 Swift tests passed, including restart round-trip of both drafts/mode, corruption preservation, write-failure retry, and deletion cleanup. App bundle build and signing succeeded. Read-only watcher reviewed persistence and flow; its restored-mode visibility finding was fixed. No paid provider calls or user workload changes were performed. Visual layout of the new controls has not been inspected in a running native window.

## 2026-10-06 — Enforced access policies and repeated log counts

- Settings > Access adds Allow changes to working files (default On), enforced by a read-only bind mount when Off, and Allow low-level system tools (default Off), enforced by dropping NET_RAW, NET_ADMIN, SYS_ADMIN, SYS_PTRACE, SYS_MODULE, SYS_RAWIO, SYS_BOOT, and SYS_TIME. On uses runtime defaults, never adds capabilities. Existing Internet and Browser preview controls remain. Changes require a stopped workspace and apply on next start. Read-only tasks receive review/analyze instructions rather than editing instructions. The restrictions do not constitute escape detection or a network destination allowlist.
- Current task activity groups exact repeated messages, including alternating messages, into one row with a count badge. A repeated row moves to its latest occurrence; counts and first/latest occurrence times persist. Archives keep counts and task boundaries. Old records migrate from the retained event strings; repetitions discarded by older builds cannot be recovered.
- Assistant output groups exact repeated retained lines separately, with count badges and a disclosure explaining trimming/grouping. Different lines remain distinct. Stable row identities avoid refresh churn. Removed the redundant current-status line from the Activity list; status remains in the status/problems section.
- Validation: 48 tests pass, including alternating repeats, persistence, archival boundaries, legacy migration, bounded retention, and policy defaults/serialization/arguments. App bundle rebuilt and signed. Read-only watcher identified unstable UI identities and conflicting read-only instructions; both fixed.
- Real Apple container 1.5.0 smoke succeeded with the current harbor-agents:v3 image: read-only /workspace rejected writes; writable /workspace allowed them; guest temporary storage remained writable; all eight dropped capabilities were absent from effective and bounding sets in an exec process; host original preserved. Two isolated temporary containers were stopped/deleted afterward. No keys or paid provider calls. Evidence: .local-data/policy-verification.json; repeatable script: scripts/verify-access-policies.py. User workloads were not stopped or changed. New layout has not been inspected in a running native window.

## 2026-10-06 — Workspace tools placement and cancellation

- Moved Local workspace tools below Access and above Assistant Credentials in workspace Settings. Project, run/resource limits, and storage controls remain above it.
- Cancel Build is available during tools preparation/build. It cancels Harbor’s owned build task and sends SIGINT to its CLI process through CommandRunner, with the existing bounded forced-termination fallback. It does not stop the shared runtime or builder and does not guarantee that remote BuildKit work has already ended; the UI and log explain this distinction.
- During service startup cancellation is unavailable with an explanation. After cancellation the UI reports Checking installed tools while bounded runtime checks verify an existing usable image. User cancellation produces no error alert, and preparation can be retried.
- Quit during a build asks to cancel and waits for Harbor’s preparation to settle; service startup must settle before quitting. Output callbacks are scoped to a preparation token to prevent delayed chunks contaminating the next attempt.
- Validation: 50 tests pass. New preparation tests verify actual SIGINT delivery to a fixture build process, graceful cancellation, existing-image readiness, retry, and unavailable cancellation during service startup. Shared Apple builder was not interrupted and no provider calls were made. Native layout/quit dialog and cancellation of a real Apple BuildKit job have not been manually exercised.
