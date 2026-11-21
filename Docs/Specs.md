# Tefter
**Status:** Approved product direction; implementation contract for three sequential coding-agent shots.  
**Audience:** Maintainer and coding agents.  

## 1. Mission and boundaries
Tefter is a small, self-hosted, filesystem-first workspace where people and AI agents collaborate on documents, tasks, links, conversations, and connected Git repositories.

**Governing principle: Files are the source of truth. Entities provide identity and relationships. Views provide presentation. Comments provide collaboration.**

Tefter is not a generic application framework, SaaS, Git hosting provider, infrastructure manager, agent fleet manager, or replacement for aeLab. It must be useful without aeLab, Docker, SMTP, external database servers, or a connected agent harness. A copied space must remain intelligible as ordinary files.

**Delivery contract:** Implement all mandatory features across **Stage 1 → Stage 2 → Stage 3**, using multiple coherent commits within each stage. The stages are execution checkpoints, not separate specifications or permission to stop after Stage 1. Do not build all three in one unreviewable change. Video is explicitly future-only. Audio is a late Stage 3 capability; see its bounded definition below.

## 2. Fixed technology and deployment
- Backend: Swift, Hummingbird, structured concurrency; Linux primary, macOS/WSL practical.
- Frontend: Svelte 5, TypeScript, Vite; compiled SPA served same-origin alongside `/api/v1`; lightweight client-side navigation. No production Node server or SSR.
- Distribution: Swift server executable **plus external compiled web assets**, configuration and data directories. Optional Caddy or other TLS reverse proxy. No required container.
- Persistence: canonical Markdown/plain files; SQLite for authoritative operational accounts/auth/session state and **rebuildable** content/search indexes. SQLite FTS5 for search.
- Internal content history: private Git with batched checkpoints for appropriate durable files; excluded from auth/secrets, ephemeral Comms, repository clones and transient session runtime. Git commits do not define write durability.
- WebSockets: Comms and agent-session streaming; regular HTTP for CRUD and history.
- Minimal dependencies; no premature generic plugin/UI framework. Share UI code with aeLab only after independently justified reuse.
- Configuration: documented environment/config file, XDG-friendly paths, strict file permissions for secrets, health/readiness endpoints, graceful shutdown and restart.

## 3. Domain and authorization
### 3.1 Installation, organization, user, space
- **Installation** is a single self-hosted server with a bootstrap administrator.
- **User** is an authenticated account; each user has a private personal space.
- **Organization** is an administrative/team membership boundary. An installation supports multiple organizations; a user may belong to multiple organizations.
- **Space** is the atomic ownership, content, membership, authorization, export and backup unit. A space is owned by one user or one organization; organizations may own multiple spaces.
- Users can switch between all spaces to which they have access. Organization membership governs eligibility for org spaces; **space membership** governs actual content access. Do not assume every org member can read every org space.
- All members of a space can read its content by default; authorized members can edit according to simple space roles. Use installation admin, space owner/admin and space member; no per-file ACL system.
- Personal spaces are private from other ordinary users. The server operator retains filesystem/backup access; privacy is not cryptographic isolation.
- The frontend is not an authorization boundary. Enforce membership and permission checks for reads, writes, search, exports, shared references, comments, Comms, Repos and sessions.

### 3.2 People and agents
- **People** is a space-level directory/view of human members and authorized agent participants.
- Installation-level user account ≠ human participant profile ≠ agent identity ≠ harness connection.
- A persistent agent is defined once at installation level and can be explicitly granted access to several spaces, with consistent attribution. Ad-hoc sessions need not create persistent agent identities.
- Readable non-secret profiles are file-backed; passwords, tokens, cookies, harness credentials and membership/auth records live in protected operational storage.
- Space membership does **not** confer operating-system, shell, network or harness execution privilege.

### 3.3 Cross-space sharing
- Stage 2 introduces **logical, authorization-checked references**, not filesystem symlinks or duplicate canonical entities.
- Content remains owned by its source space. Access requires explicit owner authorization; revocation must immediately prevent new reads, including via search, preview, cached API results and exports.
- Reference metadata may remain visible to an authorized referencing space, but unauthorized content must not leak through titles/snippets.
- Default export includes owned content and portable descriptions of shared references. Exporting copies of referenced content requires source-owner permission, with attribution preserved.

## 4. Content, identity and filesystem
### 4.1 Content types and layout
- Arbitrary directories are ordinary directories. `docs/`, `tasks/`, `links/` are optional starter folders, **not** reserved or behavior-defining names.
- Every `.md` file is browseable/editable as a Doc, even without front matter. No forced conversion on import.
- Typed content uses Markdown with YAML front matter: `task`, `sprint`, `release`, `url`. Types and views are independent of directory names.
- Stable opaque entity IDs must survive rename/move. For plain Markdown without metadata, allocate an ID only when needed and persist it in a portable sidecar/manifest rather than silently rewriting the original file. Detect ID collisions on import/copy.
- Front matter is generated/maintained by Tefter, human-readable and minimally required. Preserve unknown safe fields when editing; avoid corrupting arbitrary Markdown.
- Keep comments, references and view definitions as portable files under a per-space `.tefter/` directory. The content index in SQLite is disposable/rebuildable.

**Normative conceptual layout (precise subfile formats may be refined in implementation with documented migrations):**
```text
tefter-home/
  config/
  content/
    spaces/<space-id>/
      ...arbitrary folders and .md content...
      .tefter/
        entities.json          # ID ↔ relative path for untyped docs/metadata
        views.json             # directory defaults and saved views
        comments/<entity-id>.jsonl
        references/*.json
        people/*.md            # non-secret space-facing profiles/references
      comms/<channel-id>/YYYY/MM/YYYY-MM-DD.jsonl   # Git-excluded
  installation/
    organizations/            # non-secret readable metadata as appropriate
    agents/                   # non-secret profiles
    repos/                    # central Repo registrations
  repositories/               # Git checkouts/worktrees; never content Git
  runtime/tefter.sqlite
  runtime/sessions/
  plugins/
  secrets/
```
This is a **recommended starting layout**, not an instruction to place operational credentials in portable space exports. The agent must settle exact filenames, JSON schemas and version fields before coding the relevant slice and document them in this spec.

#### Stage 1 storage formats
Space IDs and entity IDs are UUID strings generated independently of paths. Markdown stays UTF-8. Typed Markdown uses the contract’s YAML keys. Directory names do not convey a type.

Within each space, .tefter/entities.json version 1 contains a documents array mapping id, path and revision for identified plain documents. Revision tokens are lowercase SHA-256 of exact file bytes. An unambiguous matching revision can reconcile an externally moved unmodified document. Ambiguous matches require operator reconciliation. Comments use .tefter/comments/ID.json version 1 with a comments array, replaced atomically. View preferences use .tefter/views.json version 1. Operational grants and sessions remain outside the space.

### 4.2 Example typed entities
```yaml
---
id: task_01EXAMPLE
type: task
title: Improve search indexing
status: in-progress
assignee: user_01EXAMPLE
sprint: sprint_01EXAMPLE
release: release_01EXAMPLE
---
Markdown description and checklists.
```
```yaml
---
id: url_01EXAMPLE
type: url
url: https://example.org/article
title: Example article
description: Optional extracted description
created: 2026-11-20T10:00:00Z
tags: [reading]
---
Optional personal notes.
```
Example IDs are illustrative; choose one consistent stable-ID scheme. Use ISO-8601 UTC timestamps. Keep front matter concise. URL `created` means **saved date**; distinguish publication date when available.

### 4.3 Entities, references and comments
- Entities: Docs, Tasks, Sprints, Releases, URLs; later Repo registrations and agent sessions have referencable identities. Comments can attach to any commentable entity, including these later types.
- Typed references use stable IDs and owner-space scope; resolve after moves/renames. Broken/revoked references display safely, never silently retarget.
- Comments are durable, separate from Markdown bodies, with stable ID, parent entity ID, human/agent author ID, Markdown body, created/updated timestamps, optional one-level replies, and deletion/edit semantics. Comments inherit entity permissions.
- File-backed append-only JSONL is acceptable for comments only if edit/delete semantics are implemented via explicit events or safe compaction; do **not** assume append-only lines can be overwritten arbitrarily.
- Activity events (status/assignment changes) are distinct from comments but may be rendered in one timeline.
- Preserve comment author attribution in exports and avoid exporting unauthorized shared comments.

### 4.4 Views and navigation
- Filesystem tree is primary navigation; views are alternative projections over matching entities and can span multiple folders within an authorized space.
- Save view definitions as portable file metadata, including directory default view where configured.
- Docs: tree, rendered Markdown, editor. URLs: card/grid/list with filters and sorting. Tasks: Kanban/list/Markdown plus zoom-out Sprints/Releases.
- Never encode task status or sprint/release membership by moving files between special folders.

### 4.5 Consistency and safety
- Validate all relative paths and reject traversal, unsafe symlinks and escapes from space roots. Reject unexpected filesystem object types.
- Use atomic temp-file/write/fsync/rename where supported; do not acknowledge writes before durable persistence. Guard against partial metadata/content updates with recovery procedures.
- Use optimistic concurrency (ETag/revision token, conditional update) for mutable files and comments; return explicit conflicts on stale writes.
- External edits are supported: provide explicit rescan/reindex first; filesystem watcher may follow. Handle missing/moved/duplicated IDs deterministically and surface reconciliation conflicts.
- Keep internal Git commits asynchronous/batched and recoverable after crashes. No secrets or ephemeral logs in history; do not expose private Git history to ordinary members.
- Document backup consistency and restore of canonical content **plus** operational SQLite, configuration and necessary secrets.

## 5. Stage 1 — Core workspace (mandatory)
### 5.1 Identity and spaces
- Bootstrap administrator and offline CLI recovery; email/password login (not email-code/passwordless).
- Argon2id or justified vetted equivalent; server-side sessions, secure HttpOnly SameSite cookies, CSRF protection, TLS deployment, login throttling, expiry/revocation, password change/reset and audit attribution.
- Configurable optional SMTP for invitation/recovery, never required for login or local admin recovery.
- Multiple organizations, memberships, organization-owned spaces and personal spaces; simple space switcher and roles.
- Admin-assisted user creation without SMTP dependency; no public signup.

### 5.2 Docs
- Hierarchical tree and arbitrary directories; import/browse/edit ordinary `.md` files without front matter.
- Safe create/rename/move/delete; Markdown preview and editor; stable IDs when required; optimistic concurrency; accessible loading/empty/error states.
- Sanitize rendered Markdown/HTML and URLs; no script execution.

### 5.3 URLs
- Save URL entities in arbitrary folders; title, description, favicon/OG preview when available; optional notes, tags, saved date and optional publication date.
- Asynchronous metadata fetch with timeout, size limit, allowed schemes, redirect revalidation, DNS/IP SSRF defenses (block loopback, link-local, private and metadata endpoints), and safe HTML parsing.
- Grid/list cards, tree integration, sorting/filtering/search. Allow duplicate URLs with optional warning.
- No webpage archiving, browser extension or AI summarization.

### 5.4 Tasks, Sprints and Releases
- Task Markdown: stable ID, title, `todo`/`in-progress`/`done`, optional assignee, Markdown description/checklists, optional sprint/release references.
- Sprint and Release are first-class Markdown entities with IDs, descriptions, comments and progress views.
- Task may reference at most one active sprint and one target release, either/both/neither; sprint may optionally reference release. No forced hierarchy. Backlog = view of unscheduled tasks.
- Kanban/list/Markdown task views; sprint/release overview with computed progress. Avoid mandatory estimates, priority, due date and labels.

### 5.5 Comments, search, People, export
- Durable comments on Docs/Tasks/Sprints/Releases/URLs, including authorship and one-level replies.
- Space People directory for human members; readable profiles, no credentials in files.
- SQLite FTS5 indexing of authorized content, metadata, comments and URLs; unified search scoped to current space by default, optional all accessible spaces; filters for type, directory, date and available author. Rebuildable indexes and manual rescan.
- ZIP export of a whole space or selected folders, including owned content, portable metadata, comments, view config and logical references; prevent path escapes and include a human-readable manifest. Do not leak private operational state.
- Full-instance backup/restore instructions and verification, including SQLite/auth state.

**Stage 1 acceptance gate:** Two or more accounts can authenticate, switch between private and shared spaces and safely work with Docs/URLs/Tasks/comments; multi-org membership behaves correctly; search and export respect permissions; content remains readable after copying without Tefter; stale saves conflict; restart and restore succeed; tests cover path/symlink attacks, auth, CSRF and isolation.

## 6. Stage 2 — Collaboration (mandatory)
### 6.1 Comms
- Rename product area from Chat to **Comms**. Start with ephemeral, IRC/Slack-like text channels per space.
- Automatically create `#general`; support multiple named channels. All space members see all channels; no private channels or DMs.
- Human/explicitly authorized agent authors, timestamps, basic sanitized Markdown, links, mentions and entity references.
- Persist messages as daily per-channel JSONL under `comms/<channel-id>/YYYY/MM/YYYY-MM-DD.jsonl`; exclude from Git. Default retention **30 days**, configurable at installation or space level. Ephemeral means retained until expiry, not lost on disconnect.
- HTTP history, authenticated WebSocket delivery; authorize channel subscription and every send. Handle reconnect, message ordering, duplicate delivery and backpressure reasonably. Presence is optional/later.
- Important information is promoted to durable Docs/Tasks/comments; Comms messages are not authoritative work records.
- No threads, reactions, polls, read receipts, rich embeds, file uploads, elaborate notifications or permanent Comms search in Stage 2.

### 6.2 Sharing and collaboration
- Logical cross-space sharing with explicit owner grants, revocation and no symlinks; references do not change ownership.
- Permission-aware cross-space search and previews. All-accessible-spaces search remains opt-in.
- Export shared references by default; include copies only when owner permits, with attribution.
- Allow explicitly authorized agent identities to participate in Comms without granting shell/runtime privileges.
- Extend views and cross-directory aggregation as needed without making filesystem folder names magical.

**Stage 2 acceptance gate:** Multiple clients receive live Comms events with no cross-space leaks; retention purges expired data; unauthorized shared reads and revoked grants fail; cross-space search/export never leak content; Stage 1 remains green.

## 7. Stage 3 — Repos, agents, integrations (mandatory except explicit future items)
### 7.1 Repos
- A Repo is a connected Git repository, **not** a generic Project or Git hosting service.
- Support **both** installation-level Repo registrations shared with explicitly authorized spaces and space-owned Repo registrations. One Repo model and API, two ownership scopes.
- Repo registration (identity, remote/local location, descriptive metadata, access policy) is separate from local clone/checkout and credentials. Same remote URL does not imply safe sharing of checkouts or secrets.
- Provide Repo directory/list, status/branch/commit overview where a checkout is available, and references from tasks/docs/sessions. No unauthorized Git history exposure.
- Keep Git clones/worktrees outside Tefter's private content Git. Avoid unsafe command construction and credential leaks.

### 7.2 Agent integration — deliberately modest
- Preserve separate concepts: **agent identity**, **harness adapter**, **harness connection**, **session**, **task**, **Repo**.
- Tefter connects to existing local/remote harnesses; no process fleet management, host provisioning, service monitoring or required aeLab dependency.
- Capability-driven adapters: start/message/status/stream/cancel/resume/TTY only where supported. Do not assume ACP, SSH or a universal protocol.
- Start ad-hoc sessions when supported without requiring a task, Repo or persistent persona. Optional linking to tasks/Repos; avoid elaborate lifecycle orchestration.
- Sessions record initiator, references, status, timestamps and available output/history. Distinguish durable Tefter records from harness-owned resumable context.
- Prefer structured conversation; expose TTY only when actually supported. Never claim terminal and structured chat share one synchronized execution unless adapter guarantees it.
- Session access checks must include space authorization **and** separate execution/credential policy. Streaming and cancellation must be authorized and audited.

### 7.3 Git orchestration — after basic sessions work
- Only after connectivity and basic task/Repo association are stable: optional per-session branches/worktrees, diff viewer, review and explicit merge/push approval.
- Never automatically merge or push on session completion. Worktrees reduce editing conflicts, **not** security risks.
- Remote harnesses may use their own checkout; never assume a remote process sees Tefter's local paths.

### 7.4 Plugins
- Trusted administrator-installed executable subprocesses, language-neutral, with versioned manifest and JSON stdin/stdout request/response, explicit command/hook extension points, timeouts, bounded output, exit-code handling and logs.
- Bash-friendly, not Bash-only; one demonstrative example plugin. No generic app marketplace, arbitrary UI extension framework or pretense of sandboxing.
- Plugins must not bypass the Tefter authorization boundary through user-facing APIs. Treat plugin execution as privileged administrative configuration.

### 7.5 Audio Comms and video boundary
- **Audio Comms is a late Stage 3 goal:** simple per-channel voice-room participation, join/leave, mute and participant list. Specify signaling, authentication and deployment prerequisites before implementation. Use a maintained WebRTC stack or an appropriately scoped external media component; do not hand-roll media transport.
- If audio requires disproportionate new infrastructure, document the blocker and seek maintainer approval rather than silently replacing it with a fake UI or claiming completion.
- **Video is future-only**, not required for completion.

**Stage 3 acceptance gate:** Repo registration in both scopes enforces access; at least one real supported harness adapter can establish and interact with an authorized session; unsupported capabilities are reported honestly; plugin protocol executes one safe example; code review requires explicit approval; audio either passes end-to-end acceptance or is explicitly recorded as a reviewed exception, never silently omitted.

## 8. API and UI contract
- Version all HTTP routes under `/api/v1`; use JSON for metadata and content endpoints with explicit content types, validation and consistent error envelopes.
- Cover auth/session, organizations, spaces/memberships, files/entities, views, comments, search, export, People, Comms/channels, shares, Repos, harnesses, sessions and plugins as each stage lands.
- Use stable IDs in references; never trust a client-supplied space ID without checking ownership/access. Paginate listings/search and bounded history. Expose revision tokens and conditional updates.
- WebSockets authenticate and authorize on connect **and** on subscriptions/actions; recheck on revocation. Protect against cross-origin misuse and resource exhaustion.
- UI: compact space switcher, file tree, searchable content, Markdown reader/editor, contextual views, comments/activity, URL cards, task board, Comms, Repos and session interface. Responsive, keyboard-usable, clear loading/empty/error states.
- Avoid claiming live presence, resumability or harness state unless supported by observed data.

## 9. Security, failure handling and tests
- Threat-model space boundaries, external filesystem edits, malicious Markdown, unsafe URLs, ZIP exports, symlinks, Git arguments, plugin subprocesses, harness privileges and WebSocket streams.
- No passwords, API keys, auth cookies, SMTP secrets, Git credentials or session tokens in readable profiles, exports, internal Git, logs or browser bundles.
- Audit meaningful mutations and privileged actions without leaking secret content.
- Test: auth/session/CSRF; org and space isolation; shared grant/revoke; path traversal/symlink race handling; concurrent writes; restart and crash recovery; FTS rebuild; URL SSRF; retention; WebSocket authorization; Git checkout isolation; plugin timeout; adapter capability fallbacks; export/restore round trips.
- Use real integration tests for critical boundaries. No mock-only acceptance of persistence, security or external harness support.
- Document environment variables, deployment, migration and backup steps in Docs, linked from README; keep install/run commands in README. Provide a clean setup from a fresh checkout.

## 10. Implementation process and change control
1. Inspect repository and existing working code first; preserve functioning behavior. Do not assume a greenfield checkout.
2. Read **this entire spec** before coding. Identify current stage and create a short execution plan with acceptance tests.
3. Implement vertical slices; use **multiple meaningful commits** per shot. Keep each commit buildable when feasible.
4. Run tests/build after each slice and all stage acceptance tests at stage end; fix regressions before advancing.
5. Maintain `Docs/Specs.md` alongside code when **implementation details** change; preserve approved product decisions. Record deviations, tradeoffs, migrations and incomplete items in a concise decision/progress log. Never silently delete requirements.
6. Stage 2 extends Stage 1; Stage 3 extends Stage 2. No speculative wholesale rewrites.
7. At each stage gate report completed items, test commands/results, known limitations, commit hashes and next-stage readiness.
8. For ambiguous implementation details, choose the simplest secure portable option and document it; request approval for scope/security/product changes, new mandatory services, or removal of required functionality.
9. The maintainer may run three separate agent sessions, one per stage, each reading the **same** spec and the current repository state.

## 11. Explicit non-goals and deferred capabilities
- Multi-tenant SaaS, federation, cross-instance sync, public signup, SSO, complex per-file ACLs.
- Full Slack replacement, DMs/private channels, rich chat reactions, permanent chat search, rich real-time coediting.
- Webpage archiving, browser extensions, AI summaries, sophisticated URL deduplication.
- Agent fleet operations, generalized orchestration, infrastructure monitoring, mandatory aeLab, universal terminal support.
- Automatic unreviewed Git merges/pushes, Git hosting, worktrees as a security sandbox.
- Generic plugin marketplace or dynamic UI app framework.
- Video conferencing. Audio remains a bounded late-stage requirement as defined above.

## 12. Completion definition
Tefter is complete when Stage 1, 2 and 3 mandatory acceptance gates pass, the repository builds from a clean checkout, security/portability tests pass, README links to deployment/backup/recovery documentation, and remaining exceptions are explicitly approved and documented. **A feature represented only by scaffolding or a nonfunctional UI does not count as implemented.**

### Stage 1 implementation notes

- A pending move or deletion is recorded in a version-1 `.tefter/relocation.json` before changing the directory entry. The next scan reconciles the portable ID manifest and removes the journal. A conflicting external edit during interrupted relocation is reported for operator reconciliation.
- View settings store a revision token, directory-to-view defaults and named views. Relative paths are scoped to the owning space. Comment snapshots carry a revision token and retain deleted comment identities for reply attribution.
- Operational schema version 1 uses SQLite parameter binding and Argon2id hashes. Private Git checkpoints are per space in `runtime/history/<space-id>.git`. Cold backups include these repositories along with the operational database and canonical files.

### Stage 2 implementation notes

- Operational schema 2 adds agent credentials/grants and channel sequence high-water marks, preserving existing accounts, grants and sessions. Agent bearer credentials authorize only Comms; they never grant filesystem, harness or general content API access. Non-secret agent profiles live under `installation/agents`.
- `.tefter/channels.json` version 1 contains channel UUIDs and names. Comms JSONL records contain UUID, per-channel monotonic sequence, author ID/kind, UTC creation time, body and client nonce. Atomic daily-file replacement prevents partial records; sequence gaps after failed writes are valid. Repeated author/nonce pairs are idempotent during retention. Messages are bounded at 16 KiB, daily files at 16 MiB, channels at 100 per space and history pages at 100 messages.
- Root `comms/` is server-managed ephemeral storage, excluded from content navigation, search, space ZIPs and private Git. Installation backups preserve it. Retention defaults to 30 days, configurable with `TEFTER_COMMS_RETENTION_DAYS` (1–3650); pruning runs at startup, every checkpoint interval and on channel reads/writes.

- Source owners create operational sharing grants binding source-space/entity UUID to a destination space and an explicit copy-export flag. A destination member accepts a grant as `.tefter/references/<grant-id>.json` version 1 (`id`, `source`, `entity`, `target`). Portable files carry no permission, cached title or source text; each preview, search and export resolves the current operational grant and stable entity ID. Only source owners grant/revoke sharing. Members can remove a reference without changing its source.
- Shared previews are read-only and include permission-checked comment pages. Default space exports retain references even when unavailable. `includeShared=true` explicitly requests copies and fails if any referenced source is unavailable or denies copies. Authorized copies are under `shared-copies/<grant-id>/` with content, comments, author profiles and source/entity attribution. Folder exports contain owned content only because references are space-scoped.
- WebSockets at `/api/v1/spaces/:space/channels/:channel/live?after=<sequence>` replay retained messages after the cursor and deliver ordered JSON message events. Cookie handshakes require the configured public origin (or the direct HTTP listener origin for local use); browser sends require session CSRF in the JSON `csrf` field. Bearer clients may omit Origin. Permissions/session validity are checked per send and before each delivered event; idle subscriptions recheck every 250 ms. Disconnects require reconnect from the last sequence. Clients deduplicate by sequence/message ID. Slow readers backpressure the writer; page size, frame/message size and 8-per-principal/64-total connections bound queues. No permanent Comms FTS index is built.

- The existing `document(..., identify: true)` path is exposed through a membership/CSRF-checked `POST .../identify` endpoint so Comms references can identify plain Markdown without changing its bytes. Granted agents extend the existing People view. Older spaces with a conflicting root `comms/` entry fail upgrade explicitly; nested ordinary `comms` folders remain supported.

### Stage 3 implementation notes (in progress)

- Operational schema 3 adds `repo_ownership` and `repo_grants` without changing earlier auth or collaboration records. Version-1 Repo registration JSON stores `id`, optional owner `space`, `name`, credential-free `location`, and `description`. Installation files live in `installation/repos/<id>.json`; space-owned files in `.tefter/repos/<id>.json`. SQLite ownership is authoritative for access; copied registration files do not confer grants. A registration alone never clones or executes its location. Space owners/admins register owned Repos; installation admins register central Repos and grant/revoke their access to spaces. Both use `/api/v1/repos`; space-scoped reads always require current membership and owning-space or explicit installation grant. Checkouts and credentials are separate from this metadata.
