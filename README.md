# Tefter

Tefter is a self-hosted workspace for Markdown documents, tasks, sprints, releases and saved URLs. Each space is an ordinary directory, so your content stays readable outside Tefter. Personal and shared spaces bring together editing, comments and search.

Stage 1 (the core workspace) is complete. Stage 2 (collaboration) has not started.

## Build and run

On Ubuntu 24.04, install Swift 6.4.3 and Node 24 for the build, then install the native dependencies:

```sh
sudo apt-get update
sudo apt-get install git pkg-config libargon2-dev libsqlite3-dev libcurl4-openssl-dev zlib1g-dev
```

The server uses SQLite with FTS5 and libcurl 7.85 or newer. See the [Swift installation instructions for Ubuntu](https://www.swift.org/install/linux/ubuntu/24_04/).

For macOS development, install the Xcode command-line tools and run `brew install argon2 pkg-config`.

From a fresh checkout, build the compiled browser assets and executable, then create the first account. The CLI prompts for a password or reads one line from standard input.

```sh
npm --prefix Web ci
npm --prefix Web run build
swift build -c release
.build/release/tefter bootstrap admin@example.org
.build/release/tefter
```

Open http://127.0.0.1:2909/ and sign in. Use **Account and administration** to add accounts, organizations and shared spaces.

## Documentation

- [Operations](Docs/Operations.md): configuration, deployment, storage, backup and recovery.
- [Development](Docs/Development.md): validation commands and test setup.
- [Specification](Docs/Specs.md): product direction and the three implementation stages.
- [Stage 1 log](Docs/stage-1-log.md): decisions and acceptance results.
