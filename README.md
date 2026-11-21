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
