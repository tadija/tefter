# Stage 3 progress and decisions

Current audio status: implemented; see the **Audio follow-up** below. The original acceptance report and approved deferral are retained as historical evidence.

- Read the full approved specification and inspected the existing actor, storage, authorization, HTTP, UI and integration-test patterns before editing.
- Maintainer explicitly instructed: “do not run stage 1 and 2 anything”. Earlier-stage acceptance and regression suites will not be run; this overrides the requested baseline precondition. Build validation and new Stage 3 tests remain in scope.
- Plan: Repo registrations/access; capability-driven harness sessions; optional execution links and Git review; privileged executable plugins; evaluate audio prerequisites; final security/deployment/specification reconciliation. Each slice receives focused integration checks and a coherent commit.
- Repo format: version-1 portable registration JSON; installation registrations under `installation/repos`, space registrations under `.tefter/repos`. Access grants are operational SQLite, never inferred from files, remote equality or space membership alone. Registration does not execute or clone its location. Credentials and checkout association will be separate privileged configuration.
- Repo registration slice passes `swift build`, Svelte check (zero errors/warnings), production web build, and the new real HTTP Stage 3 ownership/grant/restart test. Existing Homebrew Argon2 deployment-target linker warning remains. No Stage 1/2 suite was run.
- Real Codex CLI integration passed: denied start before an execution grant; two actual model turns with transcript continuity; finish; restart with four durable conversation turns; denial after grant revocation. No fake adapter is used for this acceptance evidence. Unsupported resume/TTY/stream/cancel are explicit capability flags and UI text. The adapter intentionally runs read-only ephemeral turns and sends Tefter's transcript, rather than claiming harness-owned resumability.
- Trusted subprocess execution uses argv and a minimal explicit environment, bounded stdout, a deadline and a separate process group whose descendants are killed on completion/timeout. Stderr is discarded to avoid credential-bearing diagnostics in API/logs. Connections store executable and credential-home pointers in operational SQLite, separate from public identities and Repo metadata. Credentials themselves remain harness-managed.
- Git slice verified with real local Git source, bare remote, cloned checkout and session worktree. A committed worktree change left checkout HEAD and remote untouched until approval; false approval was denied, stale review was rejected, explicit fast-forward merge changed only the checkout, and a separately approved push published only the session branch. Stage 3 HTTP tests passed. A transient test launch failure occurred when a build replaced the debug binary during test restart; rerunning tests after build completion passed. Build and test phases will remain sequential.
- Maintainer explicitly approved “Approve documented audio deferral” after reviewing `Audio-evaluation.md`. Audio uses the specification's reviewed-exception path. No voice-room UI or fake media is implemented; video remains future-only. No new mandatory service is introduced.
- Plugin protocol slice passes real executable tests for the word-counter command and explicit hook, administrator and CSRF denials, unsupported points/versions, timeout, output overflow, malformed JSON, nonzero exit and restart-persisted installation. No mock subprocess acceptance is used. Manifests are private administrator configuration and commands are argv-based; the server never claims a plugin sandbox.
- Final integration slice adds stable document/task → Repo/session references without rewriting plain Markdown, Repo/session comments with inherited permissions, separate mode-0600 SSH deploy keys/host pins, and explicit API/deployment/restore documentation. Focused checks prove link identity survives a source move, stale changes conflict, revoked target titles disappear, Repo metadata/comments export portably, and private keys do not export.
- Extended Stage 3 test run: six integration methods passed, including actual Codex 0.171.0 turns, a controlled in-flight revocation race (no output delivered after revoke), real Git clone/worktree/merge/push, two separate checkouts of one granted installation Repo, plugin process-group timeout/descendant termination, credential/export isolation and private asset-root rejection. A router parameter-name collision introduced while adding comments was detected by startup tests and corrected before this passing run. Existing Stage 2 migration test's expected schema was updated to 3; that suite was not executed.
- Focused browser flow passed Repo creation, actual checkout/status, durable Repo comments, execution-without-grant denial and unavailable-capability messaging. Svelte check reports zero errors/warnings and production assets build successfully.

## Final Stage 3 acceptance report

Stage 3 acceptance checks passed on macOS arm64, with the explicitly approved audio exception. Earlier-stage acceptance/regression suites were not run, as instructed; this report does not claim a fresh all-stages regression pass.

| Requirement | Result and evidence |
| --- | --- |
| Both Repo ownership scopes | Passed: installation grants, private space ownership, member/admin distinctions, immediate revocation, denied cross-space status/history and restart persistence. One installation registration cloned into two explicitly granted spaces produced independent checkouts. |
| Separate registration, credentials and checkout | Passed: registration never executes a location; checkout creation is separately privileged; mode-0600 SSH key/host pins remain outside portable files, ZIPs and content history. Credential storage/access/export were tested; a real private SSH server was not exercised. |
| Real harness and durable sessions | Passed with Codex CLI 0.171.0: actual start and two model turns, four persisted conversation entries, finish, restart and history retrieval. Separate execution policy denied ungranted starts and revoked history/comments. A controlled race fixture additionally proved in-flight output is withheld after grant revocation; that fixture is not the real-adapter acceptance evidence. |
| Honest capabilities | Start/message/status supported; resume, TTY, live streaming and cancellation explicitly unavailable in API/UI. Ephemeral CLI turns use the saved transcript, not harness-owned resumable context. |
| Task/Repo/session references and comments | Passed: optional session links; stable file-backed document/task references; source move preservation; stale revision denial; no cached title after target revoke; Repo/session comments reuse inherited authorization and durable concurrency/edit semantics. |
| Git integration and explicit review | Passed against real source/checkout/worktree/bare remote. A completed turn never merged/pushed; false/stale approval failed; owner-approved fast-forward merge and separately approved session-branch push worked. No force push or automatic main-branch publication. |
| Plugins | Passed real word-count command/hook execution, admin/CSRF denials, protocol/version checks, exit failure, malformed response, bounded output, timeout, descendant termination and installation persistence. Trusted host execution is explicit; no sandbox claim. |
| Audio | Maintainer approved the documented deferral on 2026-11-22. No working media or fake controls claimed. Video remains future-only. |
| Deployment and documentation | Debug/release builds and isolated local runs passed; production assets compiled; README/operations/integration/upgrade/backup-repair instructions updated. No external deployment target was supplied or deployed. |

### Commands and results

- `swift build`: passed.
- `swift build -c release`: passed.
- `npm --prefix Web run check`: passed, zero errors/warnings.
- `npm --prefix Web run build`: passed.
- `python3 -m unittest discover -s Tests -p stage3.py`: six methods passed, no skips (final run 19.705 seconds).
- `node Web/tests/stage3.mjs`: passed with debug executable.
- `TEFTER_TEST_BINARY=.build/release/tefter node Web/tests/stage3.mjs`: passed.
- Local Markdown link validation and `git diff --check`: passed.
- Stage 1/2 HTTP, Swift storage and original browser suites: **not run at maintainer request**. Existing schema-upgrade expectation was adjusted from 2 to 3 without executing that earlier suite.
- Linux CI configuration includes the new focused browser flow, but CI/Linux/WSL were not executed during this shot. CI's missing-Codex skip does not substitute for the successful local real-Codex acceptance test.

### Operational limits and readiness

- The local Codex adapter is read-only and transcript-based. Linked worktrees are available for operator/external editing; the adapter does not edit or automatically enter them. Revocation blocks delivery/new reads but does not cancel an already running turn; the deadline bounds it.
- Git review covers committed changes; merges are fast-forward-only and pushes publish only the session branch. Private Git authentication supports separately configured noninteractive SSH deploy keys with pinned hosts; HTTPS tokens and interactive SSH agents are unavailable. Actual private-SSH authentication remains an operator deployment check.
- Plugin hooks are explicit privileged dispatch points, not automatic triggers from ordinary user activity. Plugin executables are trusted OS processes; manifests contain no sandbox promise. Stderr is deliberately withheld from API/logs.
- Ordinary space exports omit execution records/comments to preserve separate execution authorization. Full-instance backups retain them. Relocated backups require documented `git worktree repair` and review of external executable/credential-home paths; this is not an automatically repaired restore.
- Existing Homebrew Argon2 emits a macOS-15-library versus macOS-14-target linker warning. Use compatible native libraries on the deployment host; Linux/WSL and an external production environment were not newly validated.
- Ready for maintainer Stage 3 review. No unapproved Stage 3 product-scope exception remains. A fresh complete-regression claim and target-host release verification remain outside this shot's validation evidence; earlier suites were intentionally skipped, not declared green.

Implementation commits:

- `9079341`: dual-scope Repo registration and explicit grants.
- `941a536`: capability-driven real Codex adapter, privileged execution and durable conversations.
- `721ecab`: separate checkouts/worktrees, committed review and explicit merge/push approval.
- `4dbd348`: documented and approved audio exception.
- `9dcf52e`: trusted versioned JSON plugins and real example.
- `22e8189`: stable integration references, comments, SSH credential isolation and focused security/browser coverage.
- Final documentation/report commit follows these implementation commits.

## Audio follow-up

- Maintainer subsequently requested implementation if feasible within remaining usage, superseding the earlier deferral as the desired outcome. Native browser WebRTC provides the maintained media stack; Tefter adds bounded in-memory WebSocket signaling, not custom media transport or a mandatory media service.
- Implemented six-participant per-channel human voice rooms with join/leave, mute/unmute, participant lists, microphone release and peer cleanup. Every signaling action checks CSRF/current membership; sockets check origin/session/channel access and revalidate delivery. Revoked members are evicted and surviving clients close their media connections. Signaling loss stops local media within the three-second roster lease; reconnect is an explicit rejoin.
- Audio-only HTTP/WebSocket security test passed: unauthenticated/cross-space/agent denial, origin and CSRF denial, cross-channel signaling denial, logout eviction, protected ICE configuration and mode-0600 enforcement.
- Independent Chrome processes exchanged actual audio RTP in both directions with nonzero received audio energy. Browser checks passed join/leave, actual microphone track muting, unmute, rejoin, membership eviction, connection cleanup, stopped capture tracks and signaling-loss shutdown. The stricter test explicitly requires a live connected peer and nonempty media statistics, avoiding vacuous assertions before negotiation. Synthetic microphones supply test input; media transport itself is real WebRTC.
- No TURN server was provisioned and no new mandatory service was introduced. Direct connectivity is verified; operators requiring NAT/firewall relaying can supply ICE servers privately. A live external TURN deployment/relay-only path remains unverified and is documented as a deployment validation limit, not represented as a passing network test.
- Release-browser validation exposed a departure/revocation race: SDP/ICE already in flight to a removed participant could disconnect the still-authorized sender. The server now drops stale-target signals without ejecting the sender, while still rejecting cross-room forwarding. A focused signaling regression and the two-browser revocation scenario both pass after the fix.
