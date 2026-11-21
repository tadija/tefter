# Tefter

Tefter is a self-hosted, filesystem-first workspace under development. The approved product contract is in [Docs](Docs/tefter-v1-specs.md).

## Build and run

From the project root, build the browser assets and start the Swift executable.

```sh
npm --prefix Web ci
npm --prefix Web run build
swift run tefter
```

Open http://127.0.0.1:8080/. The compiled assets in `Web/dist` are served by Hummingbird. Node is a build-time dependency. For distribution, run `swift build -c release` and deploy the executable alongside the compiled asset directory.

| Environment | Default | Purpose |
| --- | --- | --- |
| TEFTER_HOME | $XDG_DATA_HOME/tefter or ~/.local/share/tefter | Private installation data |
| TEFTER_WEB | Web/dist | Compiled public assets |
| TEFTER_HOST | 127.0.0.1 | Listen address |
| TEFTER_PORT | 8080 | Listen port |

Use `/api/v1/health` for liveness and `/api/v1/ready` for startup readiness.

Install SQLite and libargon2 development headers and pkg-config before building (on macOS, `brew install argon2 pkg-config`; on Debian, `apt install libargon2-dev libsqlite3-dev pkg-config`). Use `swift run tefter bootstrap EMAIL` for the first administrator, or `swift run tefter reset-password EMAIL` for offline recovery. Both read the password from the terminal or standard input. Recovery revokes existing sessions. Set the same TEFTER_HOME for CLI and server. Terminate TLS at a reverse proxy pointing to the loopback listener. Session cookies require a secure browser context.

## Backup and restore

Stop the server, close external content editors and run the following commands with Python 3.10 or later. Use fresh destinations outside the source tree. The backup includes content, accounts, sessions, configuration, private history and secrets. Store it with the same access restrictions as the installation. The helper locks the stopped instance, checks SQLite integrity, verifies file checksums and publishes the completed copy into the new destination. Securely preserve deployment-specific environment settings and reverse-proxy TLS keys separately.

```sh
python3 Scripts/instance.py backup "$TEFTER_HOME" /private/backups/tefter-copy
python3 Scripts/instance.py restore /private/backups/tefter-copy /private/tefter-restored
TEFTER_HOME=/private/tefter-restored swift run tefter
```

Sign in, open a known document and search for a known comment. `python3 Tests/collaboration.py` exercises this round trip with a temporary installation.

URL previews use libcurl 7.85+ and SwiftSoup. Linux builds need libcurl development headers (Debian: `libcurl4-openssl-dev`). The transport checks the concrete peer address before opening every socket, disables proxies, bounds transfer size and elapsed time, and limits redirects. Unavailable previews leave the saved URL and notes readable. Git must be available at /usr/bin/git. Private checkpoints are rebuilt from eligible durable files every 30 seconds and on startup under runtime/history.

Optional administrator-initiated password setup/recovery mail uses `TEFTER_SMTP_URL` (smtp with STARTTLS or smtps), `TEFTER_SMTP_FROM`, `TEFTER_PUBLIC_URL` (HTTPS), and optional `TEFTER_SMTP_USER` and `TEFTER_SMTP_PASSWORD`. Keep credentials in a protected service environment file. Links expire after 30 minutes and are single-use. Offline bootstrap and recovery work with the server stopped.
