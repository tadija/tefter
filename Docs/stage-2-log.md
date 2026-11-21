# Stage 2 implementation log

- Baseline `ba8ff9a`: Stage 1 preconditions passed on macOS arm64: Swift build, two storage tests, eight HTTP tests, Svelte checks/build and headless browser smoke. Existing macOS Argon2 deployment-target warning remains.
- Slice 1 extends the existing workspace actor with portable named channels, automatic general, daily durable JSONL, ordered/idempotent messages, scoped agent credentials and retention. Schema 1 installations upgrade additively to schema 2.
- Slice 2: authenticated WebSocket subscriptions and sends use the same channel checks as HTTP. Real RFC 6455 integration clients verified two-client delivery, reconnect replay, origin denial, membership revocation and logout disconnect. Frames/messages, concurrent connections and history batches are bounded.
- Slice 3: source-owner grants, recipient-accepted portable references, read-only shared content/comments, grant-filtered unified FTS and explicit authorized copy exports. Real HTTP/ZIP tests passed rename resolution, denied direct source reads, reference-only default exports, denied copies, permitted copies and immediate revoke across preview/search/export and restart.
