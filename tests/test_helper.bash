# Shared setup for the bats suite. Every test runs with a PATH that holds
# only the fake CLIs it installs plus the system tools the scripts need, so
# a reviewer CLI installed on the developer's machine never leaks in.

ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPTS="$ROOT/scripts"
HOST_BASH="$(command -v bash)"

SYSTEM_TOOLS="bash sh env cat cut tr sed awk grep head tail wc date mkdir rm rmdir mv cp ls
  basename dirname sleep kill pgrep perl jq git find xargs sort touch chmod mktemp uname
  setsid nohup readlink diff od printf true false tee ln python3"

setup_env() {
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
  SYSBIN="$BATS_TEST_TMPDIR/sysbin"
  mkdir -p "$FAKEBIN" "$SYSBIN"
  for t in $SYSTEM_TOOLS; do
    p=$(command -v "$t" 2>/dev/null) || continue
    case "$p" in /*) ln -sf "$p" "$SYSBIN/$t" ;; esac
  done
  export PATH="$FAKEBIN:$SYSBIN"
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
  # The scratchpad is reached through a symlink, as macOS reaches $TMPDIR
  # (/var -> /private/var), so path handling is tested on every host.
  export TMPDIR="$BATS_TEST_TMPDIR"
  mkdir -p "$BATS_TEST_TMPDIR/scratch.real"
  ln -sfn "$BATS_TEST_TMPDIR/scratch.real" "$BATS_TEST_TMPDIR/scratch"
  export CLAUDE_SCRATCHPAD="$BATS_TEST_TMPDIR/scratch"
  export SCRATCH_REAL; SCRATCH_REAL=$(cd "$CLAUDE_SCRATCHPAD" && pwd -P)
  export FAKE_LOG="$BATS_TEST_TMPDIR/fake.log"
  mkdir -p "$HOME" "$CLAUDE_SCRATCHPAD"
  unset OLLAMA_REVIEWER_MODEL CURSOR_CLI_MODEL KIMI_CLI_MODEL RC_CAP_SECONDS
  unset RC_CLAUDE_MODEL RC_CLAUDE_EFFORT RC_CODEX_MODEL RC_CODEX_EFFORT RC_CODEX_USAGE
  unset FAKE_MODE FAKE_CODEX_WEEK
}

setup() { setup_env; }

# A fake CLI that does nothing useful; enough for a PATH gate.
fake_plain() { # $1=name
  printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKEBIN/$1"
  chmod +x "$FAKEBIN/$1"
}

# A fake codex: writes a report to the -o file. FAKE_MODE picks the report:
#   ok (default) | noverdict | sleep (streams to stderr, never finishes)
# Each call logs "start <oss|cloud>" and "end <oss|cloud>" to $FAKE_LOG and
# its -m model to $FAKE_LOG.models. `codex app-server` answers the rate-limit
# read with a weekly usage of $FAKE_CODEX_WEEK %, or an error when unset.
fake_codex() {
  cat >"$FAKEBIN/codex" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = app-server ]; then
  while IFS= read -r l; do
    case "$l" in *'"id": 2'*)
      if [ -n "${FAKE_CODEX_WEEK:-}" ]; then
        printf '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":null},"secondary":{"usedPercent":%s,"windowDurationMins":10080,"resetsAt":null}}}}\n' "$FAKE_CODEX_WEEK"
      else
        printf '{"id":2,"error":{"message":"not signed in"}}\n'
      fi ;;
    esac
  done
  exit 0
fi
out="" kind=cloud
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -m) echo "$2" >>"$FAKE_LOG.models"; shift 2 ;;
    --oss) kind=oss; shift ;;
    *) shift ;;
  esac
done
echo "start $kind" >>"$FAKE_LOG"
case "${FAKE_MODE:-ok}" in
  ok) sleep "${FAKE_SLEEP:-0}"
      printf 'Verdict: pass\n1. a.sh:L1 | 🔵 nit | name lies. Rename.\nNot checked: nothing.\n' >"$out" ;;
  noverdict) printf 'Hello, here is my review.\n' >"$out" ;;
  sleep) echo "working" >&2; sleep 30 ;;
esac
echo "end $kind" >>"$FAKE_LOG"
EOF
  chmod +x "$FAKEBIN/codex"
}

# A fake claude whose auth check passes.
fake_claude() {
  cat >"$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
[ "$1" = auth ] && exit 0
cat >/dev/null
printf 'Verdict: pass with concerns\nNot checked: nothing.\n'
EOF
  chmod +x "$FAKEBIN/claude"
}

# A git repository whose default branch main has one commit, as origin/main
# and origin/HEAD, with the branch feature checked out on top of it.
make_repo() { # $1=dir
  git init -q "$1"
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name t
  git -C "$1" checkout -q -b main
  printf 'one\ntwo\n' >"$1/a.txt"
  git -C "$1" add a.txt
  git -C "$1" commit -q -m "first"
  git -C "$1" update-ref refs/remotes/origin/main HEAD
  git -C "$1" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$1" checkout -q -b feature
}

# One commit on feature that changes a.txt.
commit_change() { # $1=dir
  printf 'one\nTWO\nthree\n' >"$1/a.txt"
  git -C "$1" commit -q -am "change"
}

# A prepared run directory over the current branch; echoes its path.
prepared_run() {
  repo="$BATS_TEST_TMPDIR/repo"
  make_repo "$repo"
  commit_change "$repo"
  "$HOST_BASH" "$SCRIPTS/prepare-run.sh" -C "$repo" -M tribunal prepare >"$BATS_TEST_TMPDIR/run.json"
  sed -nE 's/.*"run_dir":"([^"]*)".*/\1/p' "$BATS_TEST_TMPDIR/run.json"
}
