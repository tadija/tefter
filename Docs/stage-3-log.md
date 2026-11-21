# Stage 3 progress and decisions

- Read the full approved specification and inspected the existing actor, storage, authorization, HTTP, UI and integration-test patterns before editing.
- Maintainer explicitly instructed: “do not run stage 1 and 2 anything”. Earlier-stage acceptance and regression suites will not be run; this overrides the requested baseline precondition. Build validation and new Stage 3 tests remain in scope.
- Plan: Repo registrations/access; capability-driven harness sessions; optional execution links and Git review; privileged executable plugins; evaluate audio prerequisites; final security/deployment/specification reconciliation. Each slice receives focused integration checks and a coherent commit.
- Repo format: version-1 portable registration JSON; installation registrations under `installation/repos`, space registrations under `.tefter/repos`. Access grants are operational SQLite, never inferred from files, remote equality or space membership alone. Registration does not execute or clone its location. Credentials and checkout association will be separate privileged configuration.
- Repo registration slice passes `swift build`, Svelte check (zero errors/warnings), production web build, and the new real HTTP Stage 3 ownership/grant/restart test. Existing Homebrew Argon2 deployment-target linker warning remains. No Stage 1/2 suite was run.
