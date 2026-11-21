# Development and validation

Stage 1 is complete; Stage 2 has not started. See the [specification](Specs.md) for the next acceptance gate and the [Stage 1 log](stage-1-log.md) for implementation decisions and verified results.

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
