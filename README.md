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
