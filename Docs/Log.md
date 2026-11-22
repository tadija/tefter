# Implementation log

| Stage | Delivered |
| --- | --- |
| 1 | Files, identity, views and recovery |
| 2 | Channels, sharing and agent participation |
| 3 | Repositories, agent sessions, Git approvals and channel audio |

## Stage 1

<details>
<summary>Implementation notes</summary>

- A pending move or deletion is recorded in a version-1 `.tefter/relocation.json` before changing the directory entry. The next scan reconciles the portable ID manifest and removes the journal. A conflicting external edit during interrupted relocation is reported for operator reconciliation.
- View settings store a revision token, directory-to-view defaults and named views. Relative paths are scoped to the owning space. Comment snapshots carry a revision token and retain deleted comment identities for reply attribution.
- Operational schema version 1 uses SQLite parameter binding and Argon2id hashes. Private Git checkpoints are per space in `runtime/history/<space-id>.git`. Cold backups include these repositories along with the operational database and canonical files.

</details>

<details>
<summary>Decisions and validation history</summary>

- Baseline at 10d2f8e contained the approved specification, license and placeholder README. There was no executable or test suite. [Specs.md](Specs.md) is the canonical product contract.
- Slice order: boot and static delivery, identity and memberships, portable content and concurrency, typed views and previews, collaboration/search/export/recovery, then end-to-end acceptance. The final gate requires real HTTP sessions, file copies, restart and restored-instance checks.
- Verified the startup slice with a Swift build, Vite build and live HTTP smoke test. Identity uses Argon2id (64 MiB, three passes) and protected operational SQLite. The HTTP integration test covers two organizations, separate space grants, private spaces, CSRF denial, session persistence, revocation and offline password recovery.
- The live content test imported untouched Markdown, wrote typed entities in three different folders, resolved independent sprint and release relationships, rejected a stale save, and read a copied space without the server. The SPA now exposes the tree, Markdown editor/reader and task, sprint, release, URL and People views.
- Live tests now exercise portable one-level comment replies, FTS5 matches on comments, all-accessible search isolation, authorized ZIP extraction, denied ZIP access and a cold backup restored to a new home. Restored credentials, comment bodies and search results were verified through HTTP.
- Preview work now runs off the workspace actor with bounded concurrency. A real HTTP test saved a loopback link and confirmed its preview was rejected. Startup recreated a private Git checkpoint containing the durable note. The same test verified path traversal and symlink rejection. Added optional TLS SMTP password links, self-service password changes, portable views and space-facing profiles.
- Added journaled relocation for identified documents and directories, conditional empty-directory deletion, directory view preferences, filtered link cards and bounded raster previews. The HTTP concurrency test verifies one successful writer and one conflict, then recovers a deliberately interrupted rename and checks comment identity after a directory move. A headless Chrome test passed login, editing, comments, search, reload and logout.
- Verified optional invitation/recovery by delivering mail over TLS to a disposable SMTP server and redeeming the link once. A live public HTTPS fetch saved the title “Example Domain”. Verified a second member can write to shared folders, export one folder with its comments and view defaults, and lose read/export access after revocation. Two Swift storage tests checked pinned directory identity and private metadata path components.
- Replaced the memory-backed ZIP builder with a private, streamed ZIP64-capable archive. A folder-export test includes a 17 MiB attachment, checks ZIP integrity, and verifies that sibling content and comments are excluded.
- The server supplies the URL saved timestamp on API creation and rejects multi-valued task references. Existing front matter authors are available to search. External rename reconciliation preserved comments, and an imported duplicate ID produced an explicit conflict.
- Membership revocation removes access and the current People entry. The non-secret attribution profile remains portable with comments the former member authored.

## Stage 1 acceptance gate

A fresh local clone of 5c2df06 passed on macOS arm64. Swift debug and release builds succeeded. Both Swift storage tests and all eight Python HTTP integration tests passed. Svelte type checking reported zero diagnostics, Vite built the SPA, and headless Chrome passed sign-in, editing, comments, search, reload and logout. A separately copied release executable served the external assets and authenticated a newly bootstrapped account.

Stage 1 is ready for maintainer review before Stage 2. Linux and WSL had yet to be exercised at that checkpoint. The installed Homebrew libargon2 targets macOS 15 and produced a linker warning against the package’s macOS 14 deployment target. Deployment on macOS 14 needs a compatible build of that library.

## Ubuntu verification

On Ubuntu 24.04.5 ARM64 with Swift 6.4.3 and Node 24, the debug and release builds, two Swift storage tests, eight HTTP integration tests, Svelte checks and Vite build passed. Headless Chromium passed sign-in, document editing, comments, search, reload and logout against the release executable. The Linux GitHub Actions workflow targets Ubuntu 24.04 x86-64 on pushes to main and pull requests, and supports manual runs.

</details>

## Stage 2

<details>
<summary>Implementation notes</summary>

- Operational schema 2 adds agent credentials/grants and channel sequence high-water marks, preserving existing accounts, grants and sessions. Agent bearer credentials authorize only Comms; they never grant filesystem, harness or general content API access. Non-secret agent profiles live under `installation/agents`.
- `.tefter/channels.json` version 1 contains channel UUIDs and names. Comms JSONL records contain UUID, per-channel monotonic sequence, author ID/kind, UTC creation time, body and client nonce. Atomic daily-file replacement prevents partial records; sequence gaps after failed writes are valid. Repeated author/nonce pairs are idempotent during retention. Messages are bounded at 16 KiB, daily files at 16 MiB, channels at 100 per space and history pages at 100 messages.
- Root `comms/` is server-managed ephemeral storage, excluded from content navigation, search, space ZIPs and private Git. Installation backups preserve it. Retention defaults to 30 days, configurable with `TEFTER_COMMS_RETENTION_DAYS` (1–3650); pruning runs at startup, every checkpoint interval and on channel reads/writes.

- Source owners create operational sharing grants binding source-space/entity UUID to a destination space and an explicit copy-export flag. A destination member accepts a grant as `.tefter/references/<grant-id>.json` version 1 (`id`, `source`, `entity`, `target`). Portable files carry no permission, cached title or source text; each preview, search and export resolves the current operational grant and stable entity ID. Only source owners grant/revoke sharing. Members can remove a reference without changing its source.
- Shared previews are read-only and include permission-checked comment pages. Default space exports retain references even when unavailable. `includeShared=true` explicitly requests copies and fails if any referenced source is unavailable or denies copies. Authorized copies are under `shared-copies/<grant-id>/` with content, comments, author profiles and source/entity attribution. Folder exports contain owned content only because references are space-scoped.
- WebSockets at `/api/v1/spaces/:space/channels/:channel/live?after=<sequence>` replay retained messages after the cursor and deliver ordered JSON message events. Cookie handshakes require the configured public origin (or the direct HTTP listener origin for local use); browser sends require session CSRF in the JSON `csrf` field. Bearer clients may omit Origin. Permissions/session validity are checked per send and before each delivered event; idle subscriptions recheck every 250 ms. Disconnects require reconnect from the last sequence. Clients deduplicate by sequence/message ID. Slow readers backpressure the writer; page size, frame/message size and 8-per-principal/64-total connections bound queues. No permanent Comms FTS index is built.

- The existing `document(..., identify: true)` path is exposed through a membership/CSRF-checked `POST .../identify` endpoint so Comms references can identify plain Markdown without changing its bytes. Granted agents extend the existing People view. Older spaces with a conflicting root `comms/` entry fail upgrade explicitly; nested ordinary `comms` folders remain supported.

</details>

<details>
<summary>Decisions and validation history</summary>

- Baseline `ba8ff9a`: Stage 1 preconditions passed on macOS arm64: Swift build, two storage tests, eight HTTP tests, Svelte checks/build and headless browser smoke. Existing macOS Argon2 deployment-target warning remains.
- Slice 1 extends the existing workspace actor with portable named channels, automatic general, daily durable JSONL, ordered/idempotent messages, scoped agent credentials and retention. Schema 1 installations upgrade additively to schema 2.
- Slice 2: authenticated WebSocket subscriptions and sends use the same channel checks as HTTP. Real RFC 6455 integration clients verified two-client delivery, reconnect replay, origin denial, membership revocation and logout disconnect. Frames/messages, concurrent connections and history batches are bounded.
- Slice 3: source-owner grants, recipient-accepted portable references, read-only shared content/comments, grant-filtered unified FTS and explicit authorized copy exports. Real HTTP/ZIP tests passed rename resolution, denied direct source reads, reference-only default exports, denied copies, permitted copies and immediate revoke across preview/search/export and restart.
- Slice 4 integrates Comms, channel creation, mentions, entity navigation, document/task promotion, shared previews/comments, source-owner grants/revocation, explicit exports and agent administration into the SPA. Granted agents extend the existing People directory. Two browser pages verified live delivery, sanitization, channel switching, promotion, sharing and removal of a revoked preview.
- Final hardening bounds history memory to a daily file plus 101 candidate records, avoids log scans on idle sockets, paginates grants/references/agents and rejects pre-existing managed-path collisions during upgrade. Tests cover retained log exclusion from Git/ZIP, custom retention, schema 1 upgrade with existing sessions, tampered portable references, comment attribution and revoked agent sockets. No new mandatory service or Stage 3 runtime integration was introduced.
- Security review added an external typed-file swap regression: shared search rebuilds each referenced source once per request, preventing a stale path-only FTS row from exposing a different entity after an external move. Operational grants and stable IDs remain authoritative.
- Retention-boundary review caught SQLite text binding in the sequence high-water calculation. Explicit integer conversion keeps sequences monotonic even after every retained message expires; the upgrade/retention test verifies cursor-based history still delivers the next message.

## Stage 2 acceptance gate

Passed on macOS arm64 on 2026-11-21 with the final implementation:

- `swift build` and `swift build -c release`: successful.
- `swift test`: both Swift storage tests passed.
- `python3 -m unittest discover -s Tests -p '*.py'`: all 13 integration tests passed, including the original eight Stage 1 tests.
- `npm --prefix Web run check`: zero errors and warnings; `npm --prefix Web run build`: successful.
- `TEFTER_TEST_BINARY=.build/release/tefter npm --prefix Web run test:browser`: passed original workspace behavior, two-client Comms, sanitized messages, channel switching, promotion, sharing/comment previews, revocation and logout. The expanded browser flow also passed against the debug executable during implementation.
- Local documentation links and `git diff --check`: clean.

Acceptance evidence includes two live RFC 6455 clients, nonmember/origin/CSRF denial, reconnect replay, human and agent revocation, persisted ordered messages, default and configured retention, monotonic cursors after complete expiry, stable cross-space references after rename, revoked preview/search/export denial, stale-index external swap isolation, reference-only default ZIPs, explicit owner-approved copies with comment attribution, Git/ZIP exclusion of Comms and schema 1 upgrade preserving sessions/content.

Implementation commits:

- `de6aafb`: portable Comms, agent grants and retention.
- `68ead61`: authenticated resumable WebSocket delivery.
- `cd917d7`: owner-granted references, shared search and exports.
- `cdeb6cc`: UI, identity allocation, compatibility, operational limits and validation.
- `feaa67d`: stale shared-search index isolation after external moves.
- `7e5ba8e`: monotonic sequence cursors after complete retention expiry.

Stage 2 is complete and ready for maintainer review. No required Stage 2 feature was deferred, and Stage 3 has not started. Stage 3 can extend the existing persistent agent identity model without granting execution privileges to Comms credentials.

Known operational limits and validation boundaries:

- See [Collaboration](Collaboration.md) for channel/message/daily-file/connection limits, the browser's latest-500 display, full retained HTTP history, export-copy policy and the pre-existing root `comms/` upgrade check. Retained logs are atomically rewritten per daily file; this is a small-workspace design rather than a high-volume chat transport.
- New API reads and exports enforce revocation immediately; open shared previews refresh every two seconds. Previously delivered/exported content cannot be recalled.
- The existing Homebrew Argon2 library emits a macOS 15-versus-14 deployment-target linker warning. Compatible libraries are still needed for deployment on macOS 14.
- The Linux workflow now runs the expanded integration/browser suites, but Linux and WSL were not newly verified in this session. The earlier Stage 1 Ubuntu verification remains recorded separately; it is not evidence of a Stage 2 Linux run.

</details>

## Stage 3

<details>
<summary>Implementation notes</summary>

- Operational schema 3 adds `repo_ownership` and `repo_grants` without changing earlier auth or collaboration records. Version-1 Repo registration JSON stores `id`, optional owner `space`, `name`, credential-free `location`, and `description`. Installation files live in `installation/repos/<id>.json`; space-owned files in `.tefter/repos/<id>.json`. SQLite ownership is authoritative for access; copied registration files do not confer grants. A registration alone never clones or executes its location. Space owners/admins register owned Repos; installation admins register central Repos and grant/revoke their access to spaces. Both use `/api/v1/repos`; space-scoped reads always require current membership and owning-space or explicit installation grant. Checkouts and credentials are separate from this metadata.
- Harness connections and per-user/per-space execution grants are operational tables. The `codex-exec-v1` adapter invokes an administrator-selected local Codex executable with read-only sandbox, ignored user config/rules, ephemeral JSON events and a 120-second turn deadline. Supported capabilities are start/message/status; resume, TTY, cancellation and live streaming are unavailable. It reconstructs turns from Tefter conversation records; this is not harness-context resume. Version-1 durable JSON records under `runtime/sessions/<id>.json` contain initiator, optional task/Repo IDs, UTC timestamps, status and structured conversation. Startup marks interrupted running turns explicitly. They are protected operational records, excluded from space exports and content Git. Every read/turn/finish requires current space access and an explicit user/space/connection execution grant; linked Repo access is also rechecked. No space membership or Comms agent credential implies execution permission.
- Repo checkouts are created only by installation administrators, separately under `repositories/<space>/<repo>/checkout`, including for installation registrations granted to multiple spaces. Session worktrees/branches are opt-in (`session-<execution-id>`, `tefter/<execution-id>`). A session Repo link does not imply the harness sees or edits that checkout. The initial adapter is read-only; worktrees support operator/external editing and committed review. Status/log/diff use bounded argv-based Git without hooks, external diffs, text conversion, credential helpers or interactive prompts. Merge requires the space owner's explicit approval of exact reviewed base/head commits and is fast-forward-only. Push requires separate explicit approval and sends only the reviewed session branch to `origin`, without force or automatic default-branch publication. No session lifecycle action merges or pushes.
- **Historical reviewed Stage 3 exception (superseded by the Audio follow-up below; maintainer-approved 2026-11-22):** audio was deferred as documented in [Audio evaluation](Audio-evaluation.md). The maintainer explicitly selected “Approve documented audio deferral” after reviewing the signaling/media/deployment analysis. This records the permitted exception without removing the original audio requirement; no functional audio is claimed and no mock controls are shipped.
- Repo SSH deploy keys and pinned `known_hosts` are separately administered with `PUT/DELETE /spaces/<space>/repos/<repo>/credentials`, stored privately in `secrets/git/<space>/<repo>`. Only installation admins with space/Repo access can configure them. Keys never appear in registration responses, ZIPs, content Git or audit text. HTTPS tokens and interactive SSH agents are not supported; public remotes and separately configured SSH deploy keys are supported. `/usr/bin/ssh` is needed only for SSH remotes.
- `.tefter/integration-links.json` version 1 stores a revision and stable source-entity → Repo/session references (`id`, `source`, `kind`, `target`). Creating a link identifies plain Markdown through the existing sidecar without rewriting its bytes. Links survive source moves and resolve target permissions on every read; unavailable targets reveal no cached title/history. Mutations require the current file revision. The file is included in whole-space exports and content checkpoints. Installation Repo exports contain portable ID-only reference descriptions rather than copied central registrations. Repo comments are scoped to the referencing space; execution comments additionally require current execution permission. Both reuse existing author/edit/reply/concurrency semantics. Execution records/comments are excluded from ordinary space ZIPs to preserve the separate execution boundary; full-instance backups retain them.

### Audio follow-up implementation notes

- After approving the recorded audio deferral, the maintainer requested implementation if feasible. The earlier exception remains historical; channel audio is now implemented with the maintained browser-native WebRTC stack and same-origin Tefter WebSocket signaling. No mandatory media component was added. See [Audio Comms](Audio-evaluation.md) for the exact deployment and tested contract. Video remains future-only.
- Human cookie sessions only; room/channel membership, Origin and per-action CSRF checks apply to join, mute and signaling. Server-generated peer IDs do not confer cross-room access. Room state and bounded SDP/ICE queues exist in memory only, outside Git and content exports. Limits: six participants/room, two connections/user, 64 installation-wide, ten-second unjoined reservation expiry, 32 KiB frames, 24 KiB payloads, 64 queued signals/recipient and 80 actions/second/connection.
- Clients stop microphone capture and close peers on leave/unmount/disconnect/revocation. Server authorization checks run before delivery and during 250 ms roster updates; a three-second missing-roster lease stops media. Reconnect requires explicit rejoin. Mute disables the actual microphone track. Only audio tracks are requested.
- Optional mode-0600 `secrets/audio-ice.json` supplies up to eight ICE server records (`urls`, optional `username`, `credential`) to currently authorized human channel members. No external ICE provider is enabled by default. Direct actual audio transmission is verified between independent browser processes; deployment-specific external TURN/relay-only connectivity and real microphone hardware have not been tested. This limitation is documented without claiming universal network reachability.

</details>

<details>
<summary>Decisions and validation history</summary>

Current audio status: implemented; see the **Audio follow-up** below. The original acceptance report and approved deferral are retained as historical evidence.

- Read the full approved specification and inspected the existing actor, storage, authorization, HTTP, UI and integration-test patterns before editing.
- Maintainer explicitly instructed: “do not run stage 1 and 2 anything”. Earlier-stage acceptance and regression suites will not be run; this overrides the requested baseline precondition. Build validation and new Stage 3 tests remain in scope.
- Plan: Repo registrations/access; capability-driven harness sessions; optional execution links and Git review; evaluate audio prerequisites; final security/deployment/specification reconciliation. Each slice receives focused integration checks and a coherent commit.
- Repo format: version-1 portable registration JSON; installation registrations under `installation/repos`, space registrations under `.tefter/repos`. Access grants are operational SQLite, never inferred from files, remote equality or space membership alone. Registration does not execute or clone its location. Credentials and checkout association will be separate privileged configuration.
- Repo registration slice passes `swift build`, Svelte check (zero errors/warnings), production web build, and the new real HTTP Stage 3 ownership/grant/restart test. Existing Homebrew Argon2 deployment-target linker warning remains. No Stage 1/2 suite was run.
- Real Codex CLI integration passed: denied start before an execution grant; two actual model turns with transcript continuity; finish; restart with four durable conversation turns; denial after grant revocation. No fake adapter is used for this acceptance evidence. Unsupported resume/TTY/stream/cancel are explicit capability flags and UI text. The adapter intentionally runs read-only ephemeral turns and sends Tefter's transcript, rather than claiming harness-owned resumability.
- Trusted subprocess execution uses argv and a minimal explicit environment, bounded stdout, a deadline and a separate process group whose descendants are killed on completion/timeout. Stderr is discarded to avoid credential-bearing diagnostics in API/logs. Connections store executable and credential-home pointers in operational SQLite, separate from public identities and Repo metadata. Credentials themselves remain harness-managed.
- Git slice verified with real local Git source, bare remote, cloned checkout and session worktree. A committed worktree change left checkout HEAD and remote untouched until approval; false approval was denied, stale review was rejected, explicit fast-forward merge changed only the checkout, and a separately approved push published only the session branch. Stage 3 HTTP tests passed. A transient test launch failure occurred when a build replaced the debug binary during test restart; rerunning tests after build completion passed. Build and test phases will remain sequential.
- Maintainer explicitly approved “Approve documented audio deferral” after reviewing `Audio-evaluation.md`. Audio uses the specification's reviewed-exception path. No voice-room UI or fake media is implemented; video remains future-only. No new mandatory service is introduced.
- Final integration slice adds stable document/task → Repo/session references without rewriting plain Markdown, Repo/session comments with inherited permissions, separate mode-0600 SSH deploy keys/host pins, and explicit API/deployment/restore documentation. Focused checks prove link identity survives a source move, stale changes conflict, revoked target titles disappear, Repo metadata/comments export portably, and private keys do not export.
- Extended Stage 3 test run: six integration methods passed, including actual Codex 0.171.0 turns, a controlled in-flight revocation race (no output delivered after revoke), real Git clone/worktree/merge/push, two separate checkouts of one granted installation Repo, credential/export isolation and private asset-root rejection. A router parameter-name collision introduced while adding comments was detected by startup tests and corrected before this passing run. Existing Stage 2 migration test's expected schema was updated to 3; that suite was not executed.
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
- Ordinary space exports omit execution records/comments to preserve separate execution authorization. Full-instance backups retain them. Relocated backups require documented `git worktree repair` and review of external executable/credential-home paths; this is not an automatically repaired restore.
- Existing Homebrew Argon2 emits a macOS-15-library versus macOS-14-target linker warning. Use compatible native libraries on the deployment host; Linux/WSL and an external production environment were not newly validated.
- Ready for maintainer Stage 3 review. No unapproved Stage 3 product-scope exception remains. A fresh complete-regression claim and target-host release verification remain outside this shot's validation evidence; earlier suites were intentionally skipped, not declared green.

Implementation commits:

- `9079341`: dual-scope Repo registration and explicit grants.
- `941a536`: capability-driven real Codex adapter, privileged execution and durable conversations.
- `721ecab`: separate checkouts/worktrees, committed review and explicit merge/push approval.
- `4dbd348`: documented and approved audio exception.
- `22e8189`: stable integration references, comments, SSH credential isolation and focused security/browser coverage.
- Final documentation/report commit follows these implementation commits.

## Audio follow-up

- Maintainer subsequently requested implementation if feasible within remaining usage, superseding the earlier deferral as the desired outcome. Native browser WebRTC provides the maintained media stack; Tefter adds bounded in-memory WebSocket signaling, not custom media transport or a mandatory media service.
- Implemented six-participant per-channel human voice rooms with join/leave, mute/unmute, participant lists, microphone release and peer cleanup. Every signaling action checks CSRF/current membership; sockets check origin/session/channel access and revalidate delivery. Revoked members are evicted and surviving clients close their media connections. Signaling loss stops local media within the three-second roster lease; reconnect is an explicit rejoin.
- Audio-only HTTP/WebSocket security test passed: unauthenticated/cross-space/agent denial, origin and CSRF denial, cross-channel signaling denial, logout eviction, protected ICE configuration and mode-0600 enforcement.
- Independent Chrome processes exchanged actual audio RTP in both directions with nonzero received audio energy. Browser checks passed join/leave, actual microphone track muting, unmute, rejoin, membership eviction, connection cleanup, stopped capture tracks and signaling-loss shutdown. The stricter test explicitly requires a live connected peer and nonempty media statistics, avoiding vacuous assertions before negotiation. Synthetic microphones supply test input; media transport itself is real WebRTC.
- No TURN server was provisioned and no new mandatory service was introduced. Direct connectivity is verified; operators requiring NAT/firewall relaying can supply ICE servers privately. A live external TURN deployment/relay-only path remains unverified and is documented as a deployment validation limit, not represented as a passing network test.
- Release-browser validation exposed a departure/revocation race: SDP/ICE already in flight to a removed participant could disconnect the still-authorized sender. The server now drops stale-target signals without ejecting the sender, while still rejecting cross-room forwarding. A focused signaling regression and the two-browser revocation scenario both pass after the fix.

### Audio follow-up final validation

- `swift build` and `swift build -c release`: passed after the departure-race fix. The pre-existing Homebrew Argon2 deployment-target linker warning remains.
- `npm --prefix Web run check`: zero errors/warnings; `npm --prefix Web run build`: passed.
- `python3 -m unittest discover -s Tests -p audio.py`: passed, including stale-target preservation and cross-room denial.
- `node Web/tests/audio.mjs`: passed after the fix.
- `TEFTER_TEST_BINARY=.build/release/tefter node Web/tests/audio.mjs`: passed after the fix. Independent browser endpoints received 1152/1160 audio bytes with nonzero audio energy in the final run; controls, rejoin, revocation, capture cleanup and signaling-loss shutdown passed.
- The focused Stage 3 release browser regression also passed during this follow-up. No Stage 1/2 suite or additional real-model harness test was run.
- README now describes the current product without stage/report references. Historical reports remain in Docs and are linked from Development. Audio deployment documentation records optional ICE/TURN setup and the unverified external-relay/hardware/browser limits.
- Implementation commits: `97327f3` (audio rooms and real-media/security tests), `be2b248` (departure/revocation race fix and regression). Final product documentation follows.

Audio's original deferral is superseded by the working bounded implementation. Ready for maintainer testing on real microphones and the intended deployment network; no external TURN or production host was provisioned or claimed verified.

</details>
