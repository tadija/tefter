# Collaboration

Each space has Comms channels and a Sharing view. All space members can read and send in every channel. There are no private channels or direct messages.

## Comms

Open **Comms** to use `#general` or create a named channel. Messages support sanitized Markdown, links, participant mentions and references to entities. The mention and entity selectors insert portable IDs (allocating a sidecar identity for plain Markdown without rewriting it); referenced documents open in the workspace. **Promote to document** and **Promote to task** open a new draft with message attribution. Save the draft to retain the decision beyond message expiry.

Messages survive disconnects and restarts. The browser reconnects from its last channel sequence and discards duplicate events. It displays the latest 500 received messages; the HTTP history API can page through the full retained history. Sending retries reuse a client nonce, so a lost response does not create a second message. Sequences can have gaps after an interrupted write.

Retention defaults to 30 days. Set `TEFTER_COMMS_RETENTION_DAYS` in the environment or `config/server.json` to an integer from 1 through 3650. Expired records are removed at startup, every 30 seconds and on history reads/sends. Comms is absent from search, space ZIP exports and private Git checkpoints. Full-instance backups include retained messages; manage backup retention separately.

Channels are limited to 100 per space, messages to 16 KiB, daily channel files to 16 MiB and history responses to 100 messages. A sender can publish 20 messages per ten seconds in a channel. WebSocket connections are limited to eight per principal and 64 per installation. Slow consumers apply transport backpressure rather than building an unbounded event queue. These limits fit the small self-hosted workspace; daily files are atomically rewritten on send, so this is not a high-volume chat server.

## Sharing

1. Copy the destination space ID from its Sharing view or the spaces API.
2. In the source space, its **owner** enters a source file path and destination space ID under **Source-owner grants**. Choose whether exported copies may include the content, comments and attribution.
3. Give the resulting grant ID to a destination member. That member enters it in **Grant ID** and adds a shared reference.
4. Open the reference for a read-only document and comment preview. Shared entries also appear in search; **All accessible spaces** remains an explicit opt-in.

The source retains ownership. A reference follows a stable entity ID across moves and renames. Source owners revoke grants in Sharing. Destination members may remove references without affecting source content. A revoked or missing source is shown as unavailable, without a cached title or snippet. Open shared previews revalidate every two seconds; new API reads, searches and exports check the grant immediately. Content already delivered to a client or exported cannot be recalled.

**Export with references** includes owned content and portable ID-only descriptions, even for unavailable references. **Export with owner-approved shared copies** explicitly requests copies. It fails if any reference is unavailable or the source owner denied copying. Copies are placed in `shared-copies/<grant-id>/` with `content.md`, `comments.json`, participant profiles and `ATTRIBUTION.json`. They do not become a second canonical entity. Folder exports include owned folder content only; shared references belong to the whole space.

## Agent participation

In **Sharing → Agent participation**, an installation admin registers an agent and saves its bearer token securely. The token is shown once. Space owners/admins grant or revoke its Comms access by agent ID. One persistent agent can receive grants in several spaces, retaining the same author identity. Granted agents appear in People and mention selectors. Revocation removes live access while preserving non-secret historical attribution.

Use `Authorization: Bearer TOKEN` for agent channel/history/send requests and WebSocket handshakes. These credentials cannot use the document, account, sharing or harness APIs. Human browser clients keep their existing session cookies and CSRF protection. No harness process is started in Stage 2.

<details>
<summary>API reference</summary>

## API

Paths below are under `/api/v1`:

| Method and path | Purpose |
| --- | --- |
| `GET/POST spaces/:space/channels` | List channels / create with `{name}` |
| `GET spaces/:space/channels/:channel/messages?after=0` | Ordered history page; response has `messages`, `cursor`, `more` |
| `POST spaces/:space/channels/:channel/messages` | Send `{body, nonce}`; nonce is a client UUID |
| `WS spaces/:space/channels/:channel/live?after=0` | Replay and live JSON message events; send `{body, nonce, csrf}` for human clients |
| `POST spaces/:space/identify` | Allocate/retrieve a portable identity for `{path}` without rewriting Markdown |
| `POST agents` | Installation-admin registration with `{name}`; returns `{id, token}` |
| `GET/PUT/DELETE spaces/:space/agents` | List grants / grant or revoke with `{id}` |
| `GET/POST spaces/:space/shares` | Owner lists grants / grants `{path, target, allowExport}` |
| `DELETE spaces/:space/shares/:id` | Source owner revokes grant |
| `GET/POST spaces/:space/references` | List safe previews / accept `{grant}` |
| `GET/DELETE spaces/:space/references/:id` | Authorized preview / remove local reference |
| `GET spaces/:space/export?includeShared=true` | Explicitly request authorized shared copies |

List endpoints for agents, grants and references use `offset`/`limit` and an optional `next` offset, like the existing workspace listings.

Message events contain `id`, `sequence`, `author`, `authorKind`, `created`, `body` and `nonce`. Replay only returns messages still inside retention. Connection/protocol/authorization errors close the socket; clients can check HTTP history for an actionable status before retrying. The browser sends over HTTP and receives over WebSocket. A cookie handshake requires a same-origin `Origin`; a bearer-only client may omit it. Set `TEFTER_PUBLIC_URL` to the exact HTTPS origin behind a TLS proxy, and configure that proxy to forward WebSocket upgrades. Tokens and CSRF values are never placed in URLs.

</details>

## Upgrading from Stage 1

Stop the old server and take a verified full-instance backup. Install the new executable and matching compiled web assets. Operational schema 1 upgrades additively to schema 2; existing accounts, sessions, memberships and content remain intact. Schema 2 adds agent credentials/grants, sharing grants and channel sequence counters. Unknown schema versions are rejected. To roll back, restore the pre-upgrade backup with the matching older executable.

The root `comms/` directory becomes server-managed ephemeral storage. Nested ordinary directories named `comms` remain valid content folders. If an older space already has a root `comms/` folder without channel metadata, startup fails explicitly: move that content into another ordinary directory, restart and rescan. Stable plain-document IDs reconcile unambiguous unchanged external moves. Reconcile ambiguous IDs before proceeding. No existing content is silently hidden or overwritten by migration.
