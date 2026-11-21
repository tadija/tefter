# Stage 2 implementation log

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
