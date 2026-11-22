# Development and validation

Build and test from the repository root. See the [implementation log](Log.md) for historical results.

## Validation

```sh
npm --prefix Web ci
npm --prefix Web run check
npm --prefix Web run build
swift build
swift test
python3 -m unittest discover -s Tests -p '*.py'
npm --prefix Web run test:browser
```

The browser smoke test runs headless Chrome through Playwright Core. Set `TEFTER_TEST_CHROME` to a local Chromium executable if needed. The HTTP and browser tests start isolated installations and exercise the real server, filesystem, SQLite and Git. Optional mail is tested with a loopback TLS SMTP fixture and disposable certificate.

The [Linux workflow](../.github/workflows/linux.yml) runs the Swift, HTTP integration and browser suites on Ubuntu, including a browser session against the release executable.

Stage 2 adds real RFC 6455 clients for two-client delivery, reconnect, origin/CSRF denial and human/agent revocation; HTTP/ZIP tests cover reference grants, stale search indexes, owner-controlled copies, retention and schema upgrades. The browser suite exercises Comms and sharing as well as the original workspace flow. To exercise the release executable, run `TEFTER_TEST_BINARY=.build/release/tefter npm --prefix Web run test:browser` after a release build.

## Focused Stage 3 validation

Build first, then run tests; do not rebuild the debug executable while an integration test is restarting it.

```sh
swift build
npm --prefix Web run check
npm --prefix Web run build
python3 -m unittest discover -s Tests -p stage3.py
node Web/tests/stage3.mjs
```

The real harness test uses `TEFTER_TEST_CODEX` (defaults to `codex` on PATH) and `TEFTER_TEST_CODEX_HOME` (defaults to `~/.codex`). It makes actual model calls using that explicitly authorized credential home; choose a dedicated test account/home where practical. Missing executable/credential directories skip this test, which is **not** evidence of adapter acceptance. Fixtures only test boundaries and protocol errors; the real Codex test is required for the harness gate. Browser validation here covers only Stage 3, using an isolated installation. This focused command does not execute earlier-stage test methods.

## Audio validation

The focused audio checks do not execute earlier-stage suites:

```sh
python3 -m unittest discover -s Tests -p audio.py
node Web/tests/audio.mjs
TEFTER_TEST_BINARY=.build/release/tefter node Web/tests/audio.mjs
```

The browser test uses synthetic microphones in two independent Chrome processes and requires actual received RTP bytes and nonzero audio energy. It covers room controls, capture cleanup, revocation and signaling-loss shutdown. It does not provision an external TURN server or validate a relay-only network path.

## Release identity

Set the release number in `VERSION`. Swift builds embed it with the Git commit. For a source archive without Git metadata, include the full commit hash in `BUILD`. Otherwise the build ID displays as `unknown`.
