# workflows

Shared reusable GitHub Actions workflows for the infodancer / matthewjhunter /
old-school-gamers / speculativefiction sites.

These are GitHub [reusable workflows](https://docs.github.com/en/actions/using-workflows/reusing-workflows):
a caller repo keeps a small stub that owns the trigger (`on:`) and delegates the
logic here via `uses:`. Fix a bug once, every caller picks it up on its next run.

Callers span multiple GitHub orgs, so this repo is **public** -- a private repo's
reusable workflows are only callable from within its own org. The workflows hold
no secrets; callers pass the built-in `GITHUB_TOKEN` automatically.

Pin callers to the moving major tag (`@v0`), not an exact patch tag and not
`@main`. The premise of this repo is "fix a bug once, every caller picks it up on
its next run" -- pinning `@v0.2.0` defeats that, turning every workflow change
into a manual bump across every caller repo. `v0` is re-pointed on each release
and kept backward-compatible for callers; a genuinely breaking input change gets
a `v1` rather than breaking `v0`. Same model as `actions/checkout@v6`.

The tradeoff is deliberate: a change to `v0` reaches every caller on their next
run, so anything landing here must be compatible and tested before the tag moves.
Exact tags (`@v0.2.0`) stay available for pinning a caller that needs to sit out
a change, and `@main` is never a valid pin -- it picks up unreleased work.

## Workflows

### `pr-preview-sweep.yml`

Reconciliation safety net for the per-PR preview-environment pattern
(`pr-preview.yml` + `pr-cleanup.yml`). Daily, it drops the database, container,
volume, and image for any PR that GitHub reports CLOSED or MERGED but whose
artifacts are still present (a missed cleanup event, a runner outage, a swallowed
failure). Conservative: never touches an OPEN preview or a PR whose state it
can't determine, and bounded to `<slug>`-named objects so it can't reach another
site's artifacts on the shared Postgres.

```yaml
# .github/workflows/pr-preview-sweep.yml in the caller repo
name: PR Preview Sweep
on:
  schedule:
    - cron: "43 4 * * *" # daily; stagger per site
  workflow_dispatch:

permissions:
  contents: read
  pull-requests: read

jobs:
  sweep:
    uses: infodancer/workflows/.github/workflows/pr-preview-sweep.yml@v0
    with:
      slug: sf
      image: ghcr.io/speculativefiction/sf
      # runner: '["self-hosted", "linux", "docker-web"]'  # override if needed
```

| input | required | default | notes |
|---|---|---|---|
| `slug` | yes | -- | derives db `<slug>_pr_<N>`, container `<slug>-pr-<N>`, volume `<slug>_pr_<N>_data` |
| `image` | yes | -- | full GHCR repo, e.g. `ghcr.io/owner/name`; per-PR tag is `pr-<N>` |
| `postgres_container` | no | `postgres` | container to exec `psql` inside |
| `runner` | no | `["self-hosted", "docker-web"]` | `runs-on` labels as a JSON array string |

### `go-ci.yml`

Go CI: `test` + `vet` + `fmt` + `lint` + `govulncheck`, each fanning out over a
module matrix with `GOWORK=off`. Action versions are SHA-pinned here so every
caller inherits one vetted set.

The `test` job is the one with real per-repo variance (service containers,
coverage, env). A reusable workflow can't take service containers as inputs, so
a DB-backed repo sets `run_tests: false` and keeps its own `test.yml`, calling
this for the static-analysis quartet only. A repo whose tests just need a
PostgreSQL server to create databases on can set `test_postgres_env` instead and
keep the shared test job (see below).

```yaml
# .github/workflows/ci.yml in the caller repo
name: CI
on:
  push:
    branches: [main, master]
  pull_request:

jobs:
  ci:
    uses: infodancer/workflows/.github/workflows/go-ci.yml@v0
    # multi-module + a govulncheck toolchain pin, for example:
    # with:
    #   modules: '[".", "markdown", "mdedit"]'
    #   govulncheck_go_version: "1.26.4"
    #   run_tests: false   # repo has its own service-backed test.yml
```

| input | required | default | notes |
|---|---|---|---|
| `modules` | no | `["."]` | module dirs as a JSON array string |
| `go_version` | no | `stable` | Go for test/vet/fmt/lint; `""` falls back to each module's `go.mod`, or set an exact version to pin |
| `govulncheck_go_version` | no | `stable` | Go for govulncheck only; scan with the toolchain you **ship** -- a repo pinning an older `FROM golang:` must match it here, or real stdlib vulns stay hidden |

**How the toolchain is resolved:** a `resolve-go` job runs first and resolves
`go_version` (and `govulncheck_go_version`) to an exact patch once per run;
every matrix job then installs that exact version, which is a tool-cache hit
with no network call. Previously each job resolved `stable` for itself, so a
wide matrix made the same version-manifest lookup dozens of times -- and under
that load `setup-go` was observed returning success **without installing Go**,
leaving the job to fail several steps later with a bare exit 127. Each job now
also asserts `go` is on `PATH` immediately after `setup-go`, so that failure is
reported where it happens. Setting `go_version: ""` keeps per-job resolution,
since modules may name different versions in their own `go.mod`.
| `golangci_version` | no | `v2.10.1` | golangci-lint version |
| `run_tests` | no | `true` | set false for service-backed repos that keep their own test job |
| `run_govulncheck` | no | `true` | set false for repos that must scan in binary mode (e.g. testcontainers/moby) and keep their own govulncheck job |
| `govulncheck_allow` | no | `[]` | OSV IDs (JSON array string) to report but not gate on; findings still print as warnings |
| `allow_local_replace` | no | `[]` | module paths (JSON array string) allowed to keep a filesystem `replace` pointing outside the repo; remove an entry once the dependency is tagged |
| `check_go_consistency` | no | `false` | fail when the repo's `go.mod` files disagree on the `go` directive (see below) |
| `go_version_doc` | no | `""` | path to a doc that must name the version the modules declare, e.g. `CONVENTIONS.md`; only consulted when `check_go_consistency` is true |
| `runner` | no | `["self-hosted", "linux", "ci"]` | `runs-on` labels as a JSON array string; override to `["ubuntu-latest"]` for GitHub-hosted |
| `test_postgres_env` | no | `""` | name of an env var to export a throwaway PostgreSQL DSN under for the test job, e.g. `WEB_TEST_PG`; empty starts nothing (see below) |
| `test_postgres_image` | no | `postgres:17-alpine` | image for that server; name one carrying the extensions your migrations need |

**Test PostgreSQL (`test_postgres_env`)** gives the test job a server to create
databases on, for suites that take a DSN from the environment and make a private
database per test (`infodancer/web`'s `pgtest`, memstore's `testpg`):

```yaml
    with:
      test_postgres_env: WEB_TEST_PG
```

Each test matrix job starts its own server before the tests and removes it after
them, pass or fail. It is not an Actions service container, because those fail
on the LXC runners. The runners on a host share one Docker daemon, so the server
is isolated per job: a name unique to the run, attempt and job; a port published
on loopback only, chosen at random; and a random password, masked in the log.
Readiness is probed over TCP rather than the socket, since the image's init phase
runs a temporary socket-only server that a socket probe would mistake for the
real one. A server left by a killed run carries the
`org.infodancer.go-ci=test-postgres` label and is reaped with stale
testcontainers.

Without this, such a suite skips its database tests in CI -- green, and not
testing the thing that most needs it.

**Go version consistency (`check_go_consistency`)** asserts that every tracked
`go.mod` declares the same `go` directive, and -- with `go_version_doc` -- that
the named doc mentions it. It needs no Go toolchain and adds one short job.

It is **off by default** because turning it on is a judgement about the repo:
callers whose modules legitimately sit on different versions would go red on a
change they never made. Enable it where the version moves in lockstep:

```yaml
    with:
      check_go_consistency: true
      go_version_doc: CONVENTIONS.md
```

Two real failures motivated it, both in `infodancer/web`. A nested module missed
by a suite-wide bump kept `go 1.26.5` while the parent it resolves through
`replace ../..` required `1.26.6`; since Go honours the *declaring* module's
directive, every command in that directory died at load time, and because the
module was not in the matrix nothing reported it for weeks. Separately,
`CONVENTIONS.md` drifted from the code three times, because correcting the
number was a manual step nothing enforced. The doc half is a substring match
rather than an exact check, so a changelog citing older versions still passes --
the claim enforced is that the current version appears at all.

**Migration note:** moving a repo to this reusable renames its PR checks from
`test` to `ci / test` (caller-job `/` reusable-job). If the repo has branch
protection requiring the old names, update the required-check contexts in the
same change.
