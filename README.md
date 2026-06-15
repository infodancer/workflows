# workflows

Shared reusable GitHub Actions workflows for the infodancer / matthewjhunter /
old-school-gamers / speculativefiction sites.

These are GitHub [reusable workflows](https://docs.github.com/en/actions/using-workflows/reusing-workflows):
a caller repo keeps a small stub that owns the trigger (`on:`) and delegates the
logic here via `uses:`. Fix a bug once, every caller picks it up on its next run.

Callers span multiple GitHub orgs, so this repo is **public** -- a private repo's
reusable workflows are only callable from within its own org. The workflows hold
no secrets; callers pass the built-in `GITHUB_TOKEN` automatically.

Pin callers to an exact release tag (`@v0.1.0`), not `@main`.

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
    uses: infodancer/workflows/.github/workflows/pr-preview-sweep.yml@v0.1.0
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
