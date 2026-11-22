# Tefter

Tefter is a self-hosted workspace for Markdown documents, tasks, sprints, releases, saved URLs and Comms channels. Each space is an ordinary directory, so your content stays readable outside Tefter. Personal and shared spaces bring together editing, comments, search and permission-checked cross-space references.

Connect Git repositories, work with authorized agents, review changes before merging or pushing, and talk in channel audio rooms.

## Build and run

### Linux (Ubuntu or Debian)

Install Swift for your distribution and Node.js with npm. Use the [Swift installation guide](https://www.swift.org/install/linux/) and the [Linux CI configuration](.github/workflows/linux.yml) for the tested toolchain.

```sh
sudo apt-get update
sudo apt-get install git pkg-config libargon2-dev libsqlite3-dev libcurl4-openssl-dev zlib1g-dev
```

### macOS

Install the Xcode command-line tools. Once installation finishes, install the build dependencies with [Homebrew](https://brew.sh).

```sh
xcode-select --install
brew install node argon2 pkg-config
```

### Build and start on either platform

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
- [Collaboration](Docs/Collaboration.md): Comms, sharing, agent access and upgrades.
- [Integrations](Docs/Integrations.md): Repos, execution grants, Codex, Git approval and upgrade/restore steps.
- [Audio](Docs/Audio-evaluation.md): voice rooms, connectivity and deployment requirements.
- [Development](Docs/Development.md): validation commands and test setup.
- [Specification](Docs/Specs.md): product direction and implementation contract.
- [Implementation log](Docs/Log.md) for stage decisions and validation history.

---

`done for fun`
