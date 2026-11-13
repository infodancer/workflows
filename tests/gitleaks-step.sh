#!/usr/bin/env bash
# Exercise the go-ci.yml gitleaks scan step against fixture repositories.
#
# The script under test is pulled out of go-ci.yml at run time rather than
# copied here, so this tests the step callers actually run. Each case builds an
# "origin" repo, clones it the way actions/checkout does with fetch-depth: 0
# (other branches become remote-tracking refs), runs the step in the clone, and
# checks the exit status.
#
# Planted secrets are generated per run so no secret-shaped string is ever
# committed to this repository.
#
# Requires: git, gitleaks on PATH, and yq or python3 with PyYAML.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
workflow="$here/../.github/workflows/go-ci.yml"
step_name="Scan full history for secrets"

extract_step() {
  if command -v yq >/dev/null 2>&1; then
    yq -r ".jobs.gitleaks.steps[] | select(.name == \"$step_name\") | .run" "$workflow"
  else
    python3 - "$workflow" "$step_name" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for s in wf["jobs"]["gitleaks"]["steps"]:
    if s.get("name") == sys.argv[2]:
        print(s["run"])
        break
else:
    sys.exit("step not found")
PY
  fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

step="$work/step.sh"
extract_step > "$step"
[ -s "$step" ] || { echo "FAIL: could not extract '$step_name' from $workflow"; exit 1; }

command -v gitleaks >/dev/null || { echo "FAIL: gitleaks not on PATH"; exit 1; }

# A GitHub classic PAT shape: ghp_ + 36 alphanumerics. Random each run.
fake_token() {
  printf 'ghp_%s' "$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)"
}

git_q() { git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=main -c commit.gpgsign=false "$@"; }

new_origin() {
  local d="$work/$1/origin"
  mkdir -p "$d"
  git_q -C "$d" init -q
  echo "# fixture" > "$d/README.md"
  git_q -C "$d" add README.md
  git_q -C "$d" commit -qm init
  echo "$d"
}

commit_file() { # repo path content message
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" > "$1/$2"
  git_q -C "$1" add "$2"
  git_q -C "$1" commit -qm "$4"
}

# run_case name expected_status clone_args...
pass=0 fail=0
run_case() {
  local name=$1 want=$2; shift 2
  local origin="$work/$name/origin" clone="$work/$name/clone" got=0
  git clone -q "$@" "file://$origin" "$clone"
  (cd "$clone" && bash "$step") >"$work/$name/log" 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then
    echo "ok   $name (exit $got)"
    pass=$((pass + 1))
  else
    echo "FAIL $name: want exit $want, got $got"
    sed 's/^/     | /' "$work/$name/log"
    fail=$((fail + 1))
  fi
}

# 1. Clean history passes.
o=$(new_origin clean)
commit_file "$o" main.go 'package main' "add main"
run_case clean 0

# 2. A secret at HEAD fails.
o=$(new_origin secret-at-head)
commit_file "$o" config.go "package main
const token = \"$(fake_token)\"" "add config"
run_case secret-at-head 1

# 3. A secret committed and later deleted still fails: it is in history.
o=$(new_origin secret-in-history)
commit_file "$o" config.go "package main
const token = \"$(fake_token)\"" "add config"
git_q -C "$o" rm -q config.go
git_q -C "$o" commit -qm "remove config"
run_case secret-in-history 1

# 4. A secret only on another branch fails (all refs are scanned, not just
#    the checked-out one).
o=$(new_origin secret-other-branch)
git_q -C "$o" checkout -qb feature
commit_file "$o" config.go "package main
const token = \"$(fake_token)\"" "add config"
git_q -C "$o" checkout -q main
run_case secret-other-branch 1

# 5. A caller's own .gitleaks.toml is honoured: a path allowlist suppresses
#    findings under it, while the default rules still apply elsewhere.
o=$(new_origin repo-config-allowlist)
commit_file "$o" .gitleaks.toml '[extend]
useDefault = true

[[allowlists]]
description = "fixture data"
paths = ["^fixtures/"]' "add gitleaks config"
commit_file "$o" fixtures/data.txt "token = \"$(fake_token)\"" "add fixture"
run_case repo-config-allowlist 0

o=$(new_origin repo-config-still-gates)
commit_file "$o" .gitleaks.toml '[extend]
useDefault = true

[[allowlists]]
description = "fixture data"
paths = ["^fixtures/"]' "add gitleaks config"
commit_file "$o" src/config.go "package main
const token = \"$(fake_token)\"" "add config"
run_case repo-config-still-gates 1

# 6. A caller's .gitleaksignore fingerprints are honoured.
o=$(new_origin gitleaksignore)
commit_file "$o" config.go "package main
const token = \"$(fake_token)\"" "add config"
sha=$(git -C "$o" rev-parse HEAD)
commit_file "$o" .gitleaksignore "$sha:config.go:github-pat:2" "ignore known finding"
run_case gitleaksignore 0

# 7. A scanner error (here, a malformed .gitleaks.toml) is reported as an
#    error (exit 2), not mistaken for findings (exit 1).
o=$(new_origin broken-config)
commit_file "$o" .gitleaks.toml '[extend
useDefault = true' "add broken gitleaks config"
run_case broken-config 2

# 8. A shallow clone is refused rather than scanned: a partial history would
#    pass without having looked at most of it.
o=$(new_origin shallow)
commit_file "$o" main.go 'package main' "add main"
run_case shallow 1 --depth 1

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
