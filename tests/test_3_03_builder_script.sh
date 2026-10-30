#!/usr/bin/env bash
# Verifies exercise 3.3: 3_3/builder.sh clones a GitHub repository, builds
# the Dockerfile in its root, and pushes the result to a Docker Hub
# repository, invoked as `./builder.sh <github-repo> <dockerhub-repo>`.
#
# Real `git clone` / `docker build` / `docker push` calls are stubbed out
# with fake executables placed first on PATH, so these tests run fast,
# offline, and never actually push anything to Docker Hub. They check that
# builder.sh drives those tools correctly rather than that git/docker
# themselves work.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILDER="$REPO_ROOT/3_3/builder.sh"

fail() {
  echo "FAIL: $1"
  exit 1
}

pass() {
  echo "PASS: $1"
}

[ -f "$BUILDER" ] || fail "3_3/builder.sh not found"
[ -x "$BUILDER" ] || fail "3_3/builder.sh is not executable"
pass "3_3/builder.sh exists and is executable"

# Scratch space for the fake bin dir + call log, cleaned up on exit.
SCRATCH="$(mktemp -d)"
FAKE_BIN="$SCRATCH/bin"
LOG="$SCRATCH/calls.log"
mkdir -p "$FAKE_BIN"
cleanup() {
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

# Fake `git`: instead of hitting the network, records the invocation
# (prefixed with its cwd, since the clone target may be given as a path
# relative to wherever builder.sh happened to run) and creates the target
# directory, with a Dockerfile in it (as if cloning a repo that has one in
# its root -- exercise 3.3 can assume that's the case). The target dir is
# taken as the last argument rather than assuming a fixed position, since
# solutions are free to pass extra flags before it (e.g. `git clone
# --depth 1 "$url" "$dir"`); if the last argument looks like the URL itself
# (no explicit dir given), the directory name is derived the way real git
# does -- basename of the URL with a trailing ".git" stripped.
cat > "$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
echo "git[cwd=$PWD] $*" >> "$CALL_LOG"
if [ "$1" = "clone" ]; then
  last="${@: -1}"
  case "$last" in
    http://*|https://*|git@*|ssh://*)
      name="${last##*/}"
      dir="${name%.git}"
      ;;
    *)
      dir="$last"
      ;;
  esac
  mkdir -p "$dir"
  echo "FROM alpine" > "$dir/Dockerfile"
fi
exit 0
EOF

# Fake `docker`: records the invocation (prefixed with its cwd, since a
# `docker build ... .` call is only meaningful relative to where it ran).
# `login` drains stdin, but only if it's actually a pipe (some solutions
# pipe a password in via `--password-stdin`) -- when stdin is a real
# terminal (a solution calling bare `docker login` with nothing piped in,
# run from an interactive shell), draining it would block forever waiting
# for the user to type something, so that case is skipped entirely.
# Always "succeeds" without contacting Docker Hub either way -- this fake
# is first on PATH, so a real `docker login` is never reachable regardless.
# Every other subcommand (build, push, logout, ...) just succeeds.
cat > "$FAKE_BIN/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker[cwd=$PWD] $*" >> "$CALL_LOG"
if [ "$1" = "login" ]; then
  [ -t 0 ] || cat >/dev/null
fi
exit 0
EOF

# Fake `sudo`: some solutions prefix docker calls with it (`sudo docker
# build ...`). Real sudo would either hang on a password prompt or fail
# outright in this non-interactive test environment, so this fake just
# execs its arguments directly -- no privilege escalation, no prompt --
# letting `sudo docker ...` fall straight through to the fake docker above
# exactly as if it had been called without sudo.
cat > "$FAKE_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF

chmod +x "$FAKE_BIN/git" "$FAKE_BIN/docker" "$FAKE_BIN/sudo"

# Some solutions do their own `docker login` and expect credentials from
# the environment before they'll proceed at all -- give them harmless dummy
# values so that precondition doesn't block the rest of the script from
# running (the actual `docker login` call itself is always intercepted by
# the fake docker above, real or fake credentials make no difference).
#
# builder.sh runs in a fresh, empty scratch directory every time (in a
# subshell, so the `cd` never leaks out) -- never in whatever directory
# happened to be current when the test was invoked. Only `git`/`docker` are
# stubbed here; a candidate script's own `rm -rf`, `mkdir`, `cd` etc. run
# for real, and a solution that gets its relative paths wrong (e.g. an
# empty or "." temp-dir variable) must only ever be able to destroy this
# disposable directory, not real project files.
run_builder() {
  local run_dir
  run_dir="$(mktemp -d)"
  (
    cd "$run_dir" && \
    CALL_LOG="$LOG" \
      DOCKER_USER="test-user" DOCKER_PASSWORD="test-password" DOCKER_PWD="test-password" \
      DOCKERHUB_USERNAME="test-user" DOCKERHUB_PASSWORD="test-password" \
      DOCKERHUB_TOKEN="test-token" DOCKER_TOKEN="test-token" \
      PATH="$FAKE_BIN:$PATH" "$BUILDER" "$@"
  )
  local status=$?
  rm -rf "$run_dir"
  return "$status"
}

# --- Argument validation -----------------------------------------------

: > "$LOG"
output="$(run_builder 2>&1)"
[ "$?" -ne 0 ] \
  || fail "builder.sh exited 0 when called with no arguments (expected a non-zero exit code, printed no output that told us otherwise). Its output was:
$output"
[ ! -s "$LOG" ] || fail "builder.sh invoked git/docker before validating its arguments"
pass "builder.sh rejects being called with no arguments"

: > "$LOG"
output="$(run_builder "only/one" 2>&1)"
[ "$?" -ne 0 ] \
  || fail "builder.sh exited 0 when called with only one argument ('only/one'), instead of rejecting it as missing the second (Docker Hub repo) argument. Its output was:
$output"
[ ! -s "$LOG" ] || fail "builder.sh invoked git/docker with only one argument"
pass "builder.sh rejects being called with only one argument"

# --- Happy path: clone, build, push in order ----------------------------

: > "$LOG"
GITHUB_REPO="mluukkai/express_app"
DOCKERHUB_REPO="mluukkai/testing"
run_builder "$GITHUB_REPO" "$DOCKERHUB_REPO" >/dev/null 2>&1
[ "$?" -eq 0 ] || fail "builder.sh exited non-zero on the happy path"
pass "builder.sh exits 0 on the happy path"

grep -qE "^git\[cwd=.*\] clone .*https://github.com/$GITHUB_REPO" "$LOG" \
  || fail "HTTPS clone URL should be used"
pass "builder.sh clones the given GitHub repository over https"

# An explicit tag (e.g. "$DOCKERHUB_REPO:latest") is fine -- it's the same
# image reference Docker would use by default anyway -- so it's optional
# here, not required.
# `docker build ...` and `docker image build ...` are equivalent -- "image"
# is just the long-form management-command prefix -- so either is accepted.
# The tag flag may also be bundled with other short boolean flags (e.g.
# `-qt` = `-q` quiet + `-t` tag) as long as "t" is the last letter of the
# bundle, which is the only position Docker's flag parser accepts a
# value-taking short flag in -- so that's accepted too, not just bare "-t".
# The long-form `--tag` is equally valid and accepted as well. The tag may
# also be the very last token on the line (e.g. `docker build . -t $2`,
# context given before the flag) rather than followed by more args, so the
# usual trailing space is optional at end-of-line too.
# Building with some local/throwaway tag and then running a separate
# `docker tag <local> $DOCKERHUB_REPO` before the push is an equally valid,
# common two-step way to get the same result -- so that's accepted as an
# alternative to tagging the repo directly at build time.
if ! grep -qE "^docker\[cwd=.*\] (image )?build .*(-[A-Za-z]*t|--tag) $DOCKERHUB_REPO(:[A-Za-z0-9._-]+)?( |\$)" "$LOG"; then
  build_tag_cmd=$(grep -E "^docker\[cwd=.*\] (image )?build" "$LOG" | head -1)
  build_tag_args=$(echo "$build_tag_cmd" | sed -E 's/^docker\[cwd=[^]]*\] (image )?build//')
  read -ra build_tag_tokens <<< "$build_tag_args"
  build_tag_value=""
  i=0
  while [ "$i" -lt "${#build_tag_tokens[@]}" ]; do
    tok="${build_tag_tokens[$i]}"
    case "$tok" in
      --tag) build_tag_value="${build_tag_tokens[$((i + 1))]}"; i=$((i + 2)) ;;
      --file|--platform|--target|--build-arg|--label|--network|--cache-from|--iidfile)
        i=$((i + 2)) ;;
      --*) i=$((i + 1)) ;;
      -*t) build_tag_value="${build_tag_tokens[$((i + 1))]}"; i=$((i + 2)) ;;
      -*f) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *) i=$((i + 1)) ;;
    esac
  done

  retag_ok=false
  if [ -n "$build_tag_value" ]; then
    tag_cmd=$(grep -E "^docker\[cwd=.*\] (image )?tag " "$LOG" | head -1)
    if [ -n "$tag_cmd" ]; then
      tag_src=$(echo "$tag_cmd" | awk '{for (i=1;i<=NF;i++) if ($i=="tag") {print $(i+1); exit}}')
      tag_dst=$(echo "$tag_cmd" | awk '{for (i=1;i<=NF;i++) if ($i=="tag") {print $(i+2); exit}}')
      if [ "$tag_src" = "$build_tag_value" ] \
        && echo "$tag_dst" | grep -qE "^$DOCKERHUB_REPO(:[A-Za-z0-9._-]+)?\$"; then
        retag_ok=true
      fi
    fi
  fi
  "$retag_ok" || fail "builder.sh did not run 'docker build -t $DOCKERHUB_REPO ...' (and no 'docker tag <local> $DOCKERHUB_REPO' retag before push either)"
fi
pass "builder.sh builds the image tagged as the given Docker Hub repository"

# Likewise `docker push ...` and `docker image push ...` are equivalent, and
# a boolean flag like `-q` (quiet) may precede the repo argument.
grep -qE "^docker\[cwd=.*\] (image )?push (-[A-Za-z]+ )*$DOCKERHUB_REPO(:[A-Za-z0-9._-]+)?\$" "$LOG" \
  || fail "builder.sh did not run 'docker push $DOCKERHUB_REPO'"
pass "builder.sh pushes the image to the given Docker Hub repository"

clone_line=$(grep -nE "^git\[cwd=.*\] clone" "$LOG" | head -1 | cut -d: -f1)
build_line=$(grep -nE "^docker\[cwd=.*\] (image )?build" "$LOG" | head -1 | cut -d: -f1)
push_line=$(grep -nE "^docker\[cwd=.*\] (image )?push" "$LOG" | head -1 | cut -d: -f1)
[ -n "$clone_line" ] && [ -n "$build_line" ] && [ -n "$push_line" ] \
  || fail "expected to see git clone, docker build and docker push all invoked"
[ "$clone_line" -lt "$build_line" ] && [ "$build_line" -lt "$push_line" ] \
  || fail "builder.sh did not run clone, then build, then push, in that order"
pass "builder.sh runs clone, build and push in the correct order"

# The docker build context must be the directory git cloned into, not some
# other directory -- otherwise the wrong Dockerfile / build context gets
# used. builder.sh removes its temp clone dir on exit (so it no longer
# exists by the time we get here -- can't resolve via `cd`), and both the
# clone target and the build context argument may be given as relative
# paths (relative to wherever builder.sh happened to be running, e.g. "." after
# cd-ing into the clone dir) or as absolute paths -- so both are resolved
# lexically against their command's recorded cwd rather than by touching
# the filesystem.
resolve_path() {
  local arg="$1" cwd="$2"
  local resolved="$arg"
  case "$arg" in
    /*) ;;
    *) resolved="$cwd/$arg" ;;
  esac
  # Collapse any "/./" segments (e.g. "cwd/./temp_repo" -> "cwd/temp_repo")
  # left behind by a context arg like "./temp_repo" -- lexically different
  # from "temp_repo" but the same directory on disk.
  resolved="$(printf '%s' "$resolved" | sed -E 's#/\./#/#g')"
  resolved="${resolved%/.}"
  # Drop a trailing slash (e.g. "cwd/tmp/" -> "cwd/tmp") -- same directory
  # as without it, just written with a trailing separator.
  case "$resolved" in
    */) resolved="${resolved%/}" ;;
  esac
  echo "$resolved"
}

clone_cmd=$(grep -E "^git\[cwd=.*\] clone" "$LOG" | head -1)
clone_cwd=$(echo "$clone_cmd" | sed -n 's/^git\[cwd=\(.*\)\] clone.*/\1/p')
clone_arg=$(echo "$clone_cmd" | awk '{print $NF}')
# If no explicit target dir was given to `git clone` (the last argument is
# the URL itself), the fake git above derives the directory name the way
# real git does -- basename of the URL with a trailing ".git" stripped.
# Mirror that here so this check matches what actually landed on disk.
case "$clone_arg" in
  http://*|https://*|git@*|ssh://*)
    name="${clone_arg##*/}"
    clone_arg="${name%.git}"
    ;;
esac
clone_dir=$(resolve_path "$clone_arg" "$clone_cwd")

build_cmd=$(grep -E "^docker\[cwd=.*\] (image )?build" "$LOG" | head -1)
build_cwd=$(echo "$build_cmd" | sed -nE 's/^docker\[cwd=(.*)\] (image )?build.*/\1/p')
# The context directory is the one bare (non-flag) argument -- it isn't
# necessarily the last token, since flags like -t/--tag/-f/--file can come
# after it (e.g. `docker build . -t $2`) as well as before. Walk the args,
# skipping each flag and (for value-taking ones) the token right after it,
# to find the positional context arg wherever it actually sits.
build_args=$(echo "$build_cmd" | sed -E 's/^docker\[cwd=[^]]*\] (image )?build//')
read -ra build_tokens <<< "$build_args"
context_arg=""
i=0
while [ "$i" -lt "${#build_tokens[@]}" ]; do
  tok="${build_tokens[$i]}"
  case "$tok" in
    --tag|--file|--platform|--target|--build-arg|--label|--network|--cache-from|--iidfile)
      i=$((i + 2)) ;;
    --*)
      i=$((i + 1)) ;;
    -*t|-*f)
      # short flag bundle ending in a value-taking letter (-t/-qt/-f/...)
      i=$((i + 2)) ;;
    -*)
      i=$((i + 1)) ;;
    *)
      context_arg="$tok"
      i=$((i + 1)) ;;
  esac
done
context_dir=$(resolve_path "$context_arg" "$build_cwd")

[ -n "$clone_dir" ] && [ -n "$context_dir" ] && [ "$context_dir" = "$clone_dir" ] \
  || fail "docker build's context ('$context_arg' from cwd '$build_cwd', resolved to '$context_dir') is not the directory git cloned into ('$clone_arg' from cwd '$clone_cwd', resolved to '$clone_dir')"
pass "builder.sh builds using the cloned repository as build context"

echo "All tests passed"
