#!/usr/bin/env bash
# Verifies exercise 3.4: 3_4/Dockerfile packages the 3.3 builder script into
# a Docker image (docker-in-docker via a mounted docker.sock, git available
# inside the image), invoked as
#
#   docker run -e DOCKER_USER=... -e DOCKER_PWD=... \
#     -v /var/run/docker.sock:/var/run/docker.sock \
#     builder <github-repo> <dockerhub-repo>
#
# The image is really built with `docker build` (same approach as the other
# 3_5+ tests), but the `git`/`docker` binaries the *container* finds on its
# own PATH are swapped for fakes, mounted in read-only, so the tests run
# offline and never actually clone/build/push anything for real. This only
# works because the real 3.4 solution must invoke `docker`/`git` by bare
# name (found via PATH) rather than a hardcoded absolute path -- exactly
# what running them normally from a shell would do anyway.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="$REPO_ROOT/3_4"
DOCKERFILE="$TARGET_DIR/Dockerfile"
BUILDER_SCRIPT="$TARGET_DIR/builder.sh"
IMAGE="dod-3-4-builder:test"

fail() {
  echo "FAIL: $1"
  exit 1
}

pass() {
  echo "PASS: $1"
}

[ -f "$DOCKERFILE" ] || fail "3_4/Dockerfile not found"
pass "3_4/Dockerfile exists"

[ -f "$BUILDER_SCRIPT" ] || fail "3_4/builder.sh not found"
pass "3_4/builder.sh exists"

grep -qE '^\s*ENTRYPOINT' "$DOCKERFILE" \
  || fail "3_4/Dockerfile has no ENTRYPOINT -- the image should run builder.sh directly, taking <github-repo> <docker-image> as its arguments (docker run ... builder mluukkai/express_app mluukkai/testing)"
pass "3_4/Dockerfile defines an ENTRYPOINT"

docker version >/dev/null 2>&1 \
  || fail "docker is not available/running -- this test needs a real docker daemon to build and run the 3_4 image"

echo "Building $IMAGE from 3_4/Dockerfile (this can take a moment the first time)..."
docker build -t "$IMAGE" "$TARGET_DIR" >/tmp/dod-3-4-build.log 2>&1 \
  || fail "docker build of 3_4/Dockerfile failed, see /tmp/dod-3-4-build.log:
$(cat /tmp/dod-3-4-build.log)"
pass "3_4/Dockerfile builds successfully"

cleanup() {
  rm -rf "$SCRATCH"
  docker image rm "$IMAGE" >/dev/null 2>&1
}
trap cleanup EXIT

# Scratch space: a fake bin dir mounted into the container, plus a call log
# bind-mounted over a file inside it, so the host can inspect, after each
# run, which commands the container's own PATH resolved `git`/`docker` to
# and with what arguments.
SCRATCH="$(mktemp -d)"
FAKE_BIN="$SCRATCH/bin"
LOG="$SCRATCH/calls.log"
mkdir -p "$FAKE_BIN"
: > "$LOG"
chmod 666 "$LOG"

# Fake `git`: records the invocation and creates the clone target with a
# Dockerfile in it, mirroring what a real `git clone` of a buildable repo
# would leave behind -- see tests/test_3_03_builder_script.sh for the same
# idea (this is the container-side equivalent).
cat > "$FAKE_BIN/git" <<'EOF'
#!/bin/sh
echo "git[cwd=$PWD] $*" >> /fakebin/calls.log
if [ "$1" = "clone" ]; then
  eval last=\${$#}
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

# Fake `docker`: records the invocation. `login` drains stdin (the real
# solution is expected to pipe the password in via --password-stdin) but
# only if it's actually a pipe. Every subcommand always "succeeds" without
# touching a real registry.
cat > "$FAKE_BIN/docker" <<'EOF'
#!/bin/sh
echo "docker[cwd=$PWD] $*" >> /fakebin/calls.log
if [ "$1" = "login" ]; then
  [ -t 0 ] || cat >/dev/null
fi
exit 0
EOF

chmod +x "$FAKE_BIN/git" "$FAKE_BIN/docker"

# The image's own PATH (docker:cli, alpine-based) -- fakebin is
# prepended so the fakes shadow the image's real git/docker without
# otherwise changing how the container resolves everything else it needs
# (sh, mktemp, rm, cat, ...).
CONTAINER_PATH="/fakebin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

run_builder() {
  : > "$LOG"
  docker run --rm \
    -v "$FAKE_BIN:/fakebin" \
    -v "$LOG:/fakebin/calls.log" \
    -e PATH="$CONTAINER_PATH" \
    -e DOCKER_USER="test-user" \
    -e DOCKER_PWD="test-password" \
    "$IMAGE" "$@"
}

# --- Argument validation -----------------------------------------------

output="$(run_builder 2>&1)"
[ "$?" -ne 0 ] \
  || fail "the image exited 0 when run with no arguments. Its output was:
$output"
[ ! -s "$LOG" ] || fail "the image invoked git/docker before validating its arguments"
pass "the image rejects being run with no arguments"

output="$(run_builder "only/one" 2>&1)"
[ "$?" -ne 0 ] \
  || fail "the image exited 0 when run with only one argument ('only/one'). Its output was:
$output"
[ ! -s "$LOG" ] || fail "the image invoked git/docker with only one argument"
pass "the image rejects being run with only one argument"

# --- Happy path: clone, build, login, push, in order ---------------------
#
# builder.sh isn't required to validate DOCKER_USER/DOCKER_PWD itself --
# the exercise only requires that credentials come from the environment
# (rather than, say, being hardcoded or prompted for interactively), which
# is exercised below via run_builder always supplying them. If they're
# missing/wrong in practice, the real `docker login` fails on its own.

GITHUB_REPO="mluukkai/express_app"
DOCKERHUB_REPO="mluukkai/testing"
output="$(run_builder "$GITHUB_REPO" "$DOCKERHUB_REPO" 2>&1)"
[ "$?" -eq 0 ] || fail "the image exited non-zero on the happy path. Its output was:
$output"
pass "the image exits 0 on the happy path"

grep -qE "^git\[cwd=.*\] clone .*https://github.com/$GITHUB_REPO" "$LOG" \
  || fail "HTTPS clone URL should be used"
pass "builder.sh clones the given GitHub repository over https"

grep -qE "^docker\[cwd=.*\] (image )?build .*(-[A-Za-z]*t|--tag) $DOCKERHUB_REPO(:[A-Za-z0-9._-]+)?( |\$)" "$LOG" \
  || fail "builder.sh did not run 'docker build -t $DOCKERHUB_REPO ...'"
pass "builder.sh builds the image tagged as the given Docker Hub repository"

grep -qE "^docker\[cwd=.*\] login .*test-user" "$LOG" \
  || fail "builder.sh did not log in to Docker Hub with the DOCKER_USER given via the environment"
pass "builder.sh logs in to Docker Hub using DOCKER_USER/DOCKER_PWD from the environment"

grep -qE "^docker\[cwd=.*\] (image )?push (-[A-Za-z]+ )*$DOCKERHUB_REPO(:[A-Za-z0-9._-]+)?\$" "$LOG" \
  || fail "builder.sh did not run 'docker push $DOCKERHUB_REPO'"
pass "builder.sh pushes the image to the given Docker Hub repository"

clone_line=$(grep -nE "^git\[cwd=.*\] clone" "$LOG" | head -1 | cut -d: -f1)
build_line=$(grep -nE "^docker\[cwd=.*\] (image )?build" "$LOG" | head -1 | cut -d: -f1)
login_line=$(grep -nE "^docker\[cwd=.*\] login" "$LOG" | head -1 | cut -d: -f1)
push_line=$(grep -nE "^docker\[cwd=.*\] (image )?push" "$LOG" | head -1 | cut -d: -f1)
[ -n "$clone_line" ] && [ -n "$build_line" ] && [ -n "$login_line" ] && [ -n "$push_line" ] \
  || fail "expected to see git clone, docker build, docker login and docker push all invoked"
[ "$clone_line" -lt "$build_line" ] && [ "$login_line" -lt "$push_line" ] \
  || fail "builder.sh did not run clone, then build, then login, then push, in that order"
pass "builder.sh runs clone, build, login and push in the correct order"

echo "All tests passed"
