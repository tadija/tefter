# Repositories and agent sessions

Stage 3 adds Repos and structured agent sessions to the space navigation. Channel audio is implemented using native browser WebRTC; see [Audio Comms](Audio-evaluation.md) for use and network prerequisites. Video remains future-only.

<details>
<summary>Administration and API examples</summary>

## Administration and API use

All examples below are JSON bodies for same-origin `/api/v1` requests. Sign in normally; send the `tefter` cookie and the session's `X-CSRF-Token` header on mutations. Never paste credentials into browser console code, shell history or registration locations. Use a protected HTTP client configuration or the application's authenticated requests for sensitive configuration.

### Repos

`POST /repos` accepts `{"name":"Server","location":"https://example.org/team/server.git","description":"Optional","space":"SPACE-UUID"}`. Omit `space` for an installation registration (installation admin only). Space owners/admins can register space-owned Repos. A registration does not contact its location. Use absolute paths for local repositories or credential-free `https://`, `ssh://` or `file://` locations; scp-style shorthand, embedded HTTPS user information, passwords, query strings and fragments are rejected.

`PUT /repos/REPO/grants` with `{"space":"SPACE-UUID"}` explicitly grants an installation Repo to a space. `DELETE` with the same body revokes it. Installation admins manage these grants. Space-owned Repos cannot be transferred/shared through this endpoint. A shared remote URL never joins identities, grants, credentials or checkouts.

`GET /repos?space=SPACE` lists only that space's owned/granted registrations; `GET /repos` is installation-admin-only and lists installation registrations. Listings accept `offset`/`limit`. `GET /spaces/SPACE/repos/REPO` verifies current membership and owning-space/grant access, even for installation admins. The Repos UI offers space-owned registration, status/commits and comments.

`POST /spaces/SPACE/repos/REPO/checkout` explicitly creates a checkout (installation admin with space access). Each space gets its own `repositories/SPACE/REPO/checkout`, including when an installation registration is granted to several spaces. This action executes Git with operator privileges; membership alone cannot clone arbitrary filesystem/network locations. Operators can provision a checkout at this location out of band when an installation admin has no access to a private personal space. `GET .../status` reports checkout availability, branch, HEAD, working status and ten recent commits. Checkouts, worktrees and Git credentials are excluded from space exports and private content history.

For private SSH remotes, an installation admin with space access can `PUT .../credentials` with `{"privateKey":"...","knownHosts":"..."}`; `DELETE` removes both. Use a dedicated least-privilege deploy key and pinned host keys, without an interactive passphrase. Secrets live with mode 0600 under `secrets/git/SPACE/REPO`, independently for each checkout. Git invokes SSH in batch mode with only that identity, pinned host checking and no user SSH config. No credentials are returned by the API. HTTPS token authentication and interactive SSH agents are unavailable in this release; use SSH deploy keys or provision a checkout out of band. Git stderr is withheld from APIs/logs; operators diagnose failures in their protected environment.

### Harness connections and sessions

A connection is separate from agent identity, task and Repo. The supported adapter is `codex-exec-v1`, using an existing local Codex CLI. No aeLab or always-running harness service is required. The installed CLI must support `exec --json --ephemeral --ignore-user-config --ignore-rules --skip-git-repo-check --sandbox read-only`. Configure/authenticate its dedicated credential home as the service OS user before enabling access. The real integration check in this stage used Codex CLI 0.171.0 with actual model calls.

Installation admins configure a connection using `POST /harnesses`:

```json
{"name":"Read-only Codex","executable":"/absolute/path/to/codex","credentialHome":"/private/dedicated/codex-home","allowAdHoc":true}
```

`credentialHome` is the **CODEX_HOME directory**, not its parent home. Its auth files remain harness-managed, outside portable space content. Keep it outside public assets and protect it as a secret. Tefter supplies a minimal environment, ignores user config/rules, and creates an empty per-session working directory under `runtime/harness-work`. It does not copy credentials or load a persistent persona. Existing Comms agent bearer credentials cannot use these APIs.

`PUT /harnesses/CONNECTION/grants` with `{"space":"SPACE","user":"USER"}` authorizes a particular human in a particular space. `DELETE` revokes that execution grant. Current space membership is also required. No implicit execution grant is given to space members, owners or installation admins.

`GET /spaces/SPACE/harnesses` reports authorized connections and capability flags. Supported: start, message, status. Unavailable: harness-owned resume, TTY, cancellation and live output streaming. Each message runs an ephemeral read-only CLI turn with the saved conversation transcript; this is structured conversation continuity, not synchronized chat/terminal or restored harness context. A Repo link does not give the CLI that checkout as its working directory. This adapter supports conversation and read-only reasoning; editing a worktree through the adapter is not claimed.

`POST /spaces/SPACE/executions` accepts `{"connection":"ID","message":"Prompt","task":null,"repo":null}`. Task/Repo links are optional and authorization-checked; task IDs must resolve to task entities in the current space. Connections can disable unlinked ad-hoc starts. The Sessions UI exposes these choices. `GET .../executions` and `GET .../executions/ID` provide durable history/status. `POST .../executions/ID/messages` accepts `{"message":"Next turn"}`; `POST .../finish` durably closes the record. A finished record cannot receive more messages. Start/turn requests return after execution, with a 120-second maximum; configure the reverse proxy's request timeout above this. Reload the record after a client timeout. Startup marks previously running records `interrupted`; it does not pretend to resume them.

At most four turns execute concurrently. User messages are limited to 16 KiB, subprocess stdout to 1 MiB, transcripts to fewer than 100 conversation entries and approximately 8 MiB before another turn. Every history, message, finish, review and session comment checks current execution and space access; linked Repo access is also required. Revoking access prevents new output/history reads. Previously delivered data cannot be recalled. Revocation does not cancel an already running CLI turn; it remains bounded by its deadline.

Session JSON records live under `runtime/sessions`. They survive restarts and full-instance backups, but are deliberately excluded from ordinary space exports because those exports require space membership rather than execution privilege. Documents and tasks can attach stable Repo/session references in **Repo and session references**. The API is `GET /spaces/SPACE/integration-links?path=RELATIVE-MARKDOWN-PATH` and `POST` to the same resource with `path`, current `revision`, `kind` (`repo` or `session`) and `target` ID; supply `remove` with a link ID to delete it. Plain Markdown bytes stay unchanged; the existing portable sidecar identifies the source. Moves preserve the link identity, and revoked/unavailable targets expose no cached title or output.

Repo/session comments have the existing version-1 comment format with optimistic revisions and author-only edit/delete. Owned Repo metadata/comments are portable in whole-space ZIPs. Installation Repo metadata and execution histories are not copied into those ZIPs. Comments use `GET/POST /spaces/SPACE/repos/ID/comments` or `/executions/ID/comments`, with the existing comment-change body (`path` is an ignored compatibility field, use `""`).

### Git review and approval

After a Repo-linked session exists, explicitly `POST .../executions/ID/worktree` to create `tefter/ID` and `repositories/SPACE/REPO/session-ID`. Operators/external tools can edit and commit there. `GET .../executions/ID/review` returns the committed diff, reviewed `head` and checkout `base`. Uncommitted changes are not included; commit them before review. Diff overflow fails visibly rather than returning a partial review.

The Sessions UI displays that committed diff and offers separate, clearly labelled merge and push approval actions. Both require the current space owner and execution grant. `POST .../merge` or `/push` requires:

```json
{"approve":true,"head":"EXACT-REVIEWED-HEAD","base":"EXACT-REVIEWED-BASE"}
```

Changed commits require a new review. Merge is fast-forward-only; divergent branches require operator reconciliation. Push is separate and publishes only the reviewed `tefter/ID` branch to `origin`, without force. It does not publish the checkout's main branch. Session completion never merges or pushes. Worktrees isolate editing directories, not execution security.

</details>

## Upgrades, backup and deployment

Stop Tefter and take a verified cold backup before upgrading. Schema 3 adds Repo ownership/grants, harness connections/execution grants and execution-record identities additively from schemas 1/2, preserving auth and membership records. Copied registration files do not confer operational ownership or authorization. Unindexed orphan records after a crash require operator reconciliation; do not import grants from copied metadata.

Full-instance backups must include `repositories`, `secrets`, operational SQLite and `runtime/sessions`, alongside the existing content/config/history. Separately back up external harness credential homes. Stop external harnesses/editors before copying. After restoring **to a new absolute path**, repair Git worktree pointers for each checkout before using session worktrees:

```sh
git -C /restored/tefter/repositories/SPACE/REPO/checkout worktree repair \
  /restored/tefter/repositories/SPACE/REPO/session-SESSION
```

Repeat for every worktree (or pass several worktree paths to one repair command). Verify with `git worktree list` and `git status` in each restored worktree. External executable paths and credential-home pointers may need administrator reconfiguration after moving hosts. Do not expose installation, runtime, secret or repository directories as web assets. The private repository root is rejected by the server's asset-path check. The same single Swift executable, external compiled assets and TLS reverse proxy remain sufficient; Codex is optional. Audio uses browser WebRTC and the existing signaling server; external ICE/TURN services are optional deployment configuration.
