# Operations

See the [README](../README.md) for build and first-run instructions.

## Accounts and spaces

In **Account and administration**, create another account, create an organization, grant organization membership, create an organization space and grant space membership. The space switcher lists accessible personal and shared spaces. Members can edit content. Owners and space admins manage space grants. Installation admins manage organizations and accounts.

## Deployment and recovery

For deployment, install the executable and external `Web/dist` assets, keep the linked system libraries available and set the service working directory or absolute asset path. Run the process as a dedicated OS account. Put a TLS reverse proxy in front of the loopback listener. Secure HttpOnly session cookies expire after 12 hours. Password changes and recovery revoke all sessions for the account. Stop the server and run `tefter reset-password EMAIL` for offline recovery.

## Configuration

| Environment | Default | Purpose |
| --- | --- | --- |
| TEFTER_HOME | $XDG_DATA_HOME/tefter or ~/.local/share/tefter | Private installation root |
| TEFTER_WEB | Web/dist | Compiled public assets |
| TEFTER_HOST | 127.0.0.1 | Listen address |
| TEFTER_PORT | 2909 | Listen port |
| TEFTER_COMMS_RETENTION_DAYS | 30 | Comms retention in days (1–3650) |
| TEFTER_PUBLIC_URL | unset | Public HTTPS origin for mail links and WebSocket origin validation |
| TEFTER_SMTP_URL, TEFTER_SMTP_FROM | unset | SMTP endpoint and sender. SMTP requires STARTTLS or implicit TLS |
| TEFTER_SMTP_USER, TEFTER_SMTP_PASSWORD | unset | Optional SMTP credentials |
| TEFTER_SMTP_CA_FILE | system trust store | Optional private CA certificate bundle for SMTP |

The service environment overrides optional settings in `$TEFTER_HOME/config/server.json`. Place an SMTP password in `secrets/smtp-password` with mode 0600 or use a protected service environment. A minimal config file is shown below.

```json
{"version":1,"settings":{"TEFTER_HOST":"127.0.0.1","TEFTER_PORT":"2909"}}
```

Use `/api/v1/health` for liveness and `/api/v1/ready` for startup readiness. SIGTERM initiates graceful shutdown. Local login, account creation and offline recovery work independently of SMTP. An administrator can email an existing account a single-use password setup link valid for 30 minutes.

See [Collaboration](Collaboration.md) for channel retention, sharing/export policy, agent credentials and Stage 1 upgrade steps.

## Storage and operation

- Add ordinary Markdown files anywhere under `content/spaces/SPACE-ID`. Use **Rescan** after external edits to reconcile identity and rebuild search. Front matter determines typed views. A plain document receives a portable sidecar ID when needed for comments.
- Saving files and moving or deleting them requires the current revision. A stale save returns HTTP 409. Reload the file and reconcile edits. Interrupted relocations have a recovery journal. Resolve ambiguous external moves or duplicate IDs in the files before rescanning.
- The API paginates tree, membership and directory listings with `offset` and `limit`. Search returns at most 100 matches per offset. Editable Markdown and metadata reads/writes are bounded at 16 MiB. ZIP exports spool to a private temporary file and stream to the client. Attachments are copied in chunks.
- Link previews allow HTTP and HTTPS. The transport checks the actual IP before each socket opens, disables proxies, follows up to three redirects, reads at most 512 KiB per transfer and times out after five seconds. The file and notes remain available if preview generation fails.
- Private Git checkpoints run on startup and every 30 seconds under `runtime/history` using `/usr/bin/git`. The server stages validated durable files in an isolated work tree. File writes are durable before the next checkpoint.
- Operational schema version 3 adds Repo and harness/execution tables additively; collaboration tables remain intact. The executable rejects unknown schema versions. Before future upgrades, stop the server and take a verified backup.

See [Integrations](Integrations.md) for Stage 3 execution/credential policy, optional executable prerequisites, and Git worktree repair after relocating a backup.

See [Audio Comms](Audio-evaluation.md) for HTTPS/microphone requirements, optional protected ICE/TURN configuration and voice-room limits.

## Full-instance backup and restore

Stop the server, close external content editors and select fresh destinations outside the source. The standard-library helper (Python 3.10+) takes the instance lock, checks SQLite integrity, verifies file checksums and publishes the completed copy into the new directory. Backups contain accounts, session tokens, configuration, private Git history and secrets. Restrict access accordingly. Preserve external service environment files and reverse-proxy keys separately.

```sh
python3 Scripts/instance.py backup "$TEFTER_HOME" /private/backups/tefter-copy
python3 Scripts/instance.py restore /private/backups/tefter-copy /private/tefter-restored
TEFTER_HOME=/private/tefter-restored .build/release/tefter
```

Sign in to the restored instance, open a known document, check its comments and search for a known term. The integration suite performs this round trip and checks that a changed backup fails verification.

## Checkpoint recovery

If checkpoints repeatedly fail after an unclean shutdown, stop the server and back up the installation. With no Git process using the affected private repository, inspect it with `git --git-dir="$TEFTER_HOME/runtime/history/SPACE-ID.git" fsck`. Clear a confirmed stale Git lock before restarting. The next checkpoint reads the canonical space files again.
