# Shared setup for the bats suite. Every test runs with a PATH that holds
# only the fake CLIs it installs plus the system tools the scripts need, so
# a reviewer CLI installed on the developer's machine never leaks in.

ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPTS="$ROOT/scripts"
HOST_BASH="$(command -v bash)"

SYSTEM_TOOLS="bash sh env cat cut tr sed awk grep head tail wc date mkdir rm rmdir mv cp ls
  basename dirname sleep kill pgrep perl jq git find xargs sort touch chmod mktemp uname
  setsid nohup readlink diff od printf true false tee"

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
  export TMPDIR="$BATS_TEST_TMPDIR"
  export CLAUDE_SCRATCHPAD="$BATS_TEST_TMPDIR/scratch"
  export FAKE_LOG="$BATS_TEST_TMPDIR/fake.log"
  mkdir -p "$HOME" "$CLAUDE_SCRATCHPAD"
  unset OLLAMA_REVIEWER_MODEL CODEX_MODEL CURSOR_CLI_MODEL KIMI_CLI_MODEL RC_CAP_SECONDS
  unset RC_CLAUDE_MODEL RC_CLAUDE_EFFORT FAKE_MODE
}

setup() { setup_env; }

# A fake CLI that does nothing useful; enough for a PATH gate.
fake_plain() { # $1=name
  printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKEBIN/$1"
  chmod +x "$FAKEBIN/$1"
}

# A fake codex: writes a report to the -o file. FAKE_MODE picks the report:
#   ok (default) | noverdict | sleep (streams to stderr, never finishes)
# Each call logs "start <oss|cloud>" and "end <oss|cloud>" to $FAKE_LOG.
fake_codex() {
  cat >"$FAKEBIN/codex" <<'EOF'
#!/usr/bin/env bash
out="" kind=cloud
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
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

# A git repository with one commit and, optionally, uncommitted changes.
make_repo() { # $1=dir
  git init -q "$1"
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name t
  printf 'one\ntwo\n' >"$1/a.txt"
  git -C "$1" add a.txt
  git -C "$1" commit -q -m "first"
}

# A prepared run directory over an uncommitted change; echoes its path.
prepared_run() {
  repo="$BATS_TEST_TMPDIR/repo"
  make_repo "$repo"
  printf 'one\nTWO\nthree\n' >"$repo/a.txt"
  "$HOST_BASH" "$SCRIPTS/prepare-run.sh" -C "$repo" -M tribunal prepare uncommitted >"$BATS_TEST_TMPDIR/run.json"
  sed -nE 's/.*"run_dir":"([^"]*)".*/\1/p' "$BATS_TEST_TMPDIR/run.json"
}
