#!/usr/bin/env bash
# Verifies exercise 3.8: 3_89/Dockerfile.frontend is a genuine multi-stage
# build -- a build stage that runs npm install/npm run build, and a
# separate, leaner final stage that only copies over the built "build"
# folder (via COPY --from=<build stage>), not the original source or
# node_modules. The exercise explicitly allows swapping `serve` for
# something else, so nothing here assumes a particular static file server --
# the frontend's container port is read from its Dockerfile (EXPOSE, or
# falling back to serve's own "-l <port>" CMD argument) instead of assumed.
# There's no backend involved here -- this only checks that the frontend
# image builds, starts, and is reachable on its own.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRONTEND_DOCKERFILE="$REPO_ROOT/3_89/Dockerfile.frontend"

FRONTEND_IMAGE="dod-3-8-frontend:test"
FRONTEND_CONTAINER="dod-3-8-frontend-test"

fail() {
  echo "FAIL: $1"
  exit 1
}

pass() {
  echo "PASS: $1"
}

cleanup() {
  docker rm -f "$FRONTEND_CONTAINER" >/dev/null 2>&1
}
trap cleanup EXIT

[ -f "$FRONTEND_DOCKERFILE" ] || fail "3_89/Dockerfile.frontend not found"
pass "3_89/Dockerfile.frontend exists"

# Must actually be multi-stage: more than one FROM instruction.
from_count=$(grep -cE '^\s*FROM\s+' "$FRONTEND_DOCKERFILE")
[ "$from_count" -ge 2 ] \
  || fail "Dockerfile.frontend has only $from_count FROM instruction(s) -- use a genuine multi-stage build (a build stage + a final stage)"
pass "Dockerfile.frontend is multi-stage ($from_count FROM instructions)"

# Everything from the last FROM instruction onward is the final stage --
# that's what ends up in the shipped image.
final_stage() {
  awk 'BEGIN{s=0} /^[[:space:]]*FROM[[:space:]]/{s=NR} {a[NR]=$0} END{for(i=s;i<=NR;i++) print a[i]}' "$1"
}
FINAL_STAGE="$(final_stage "$FRONTEND_DOCKERFILE")"

echo "$FINAL_STAGE" | grep -q -- '--from=' \
  || fail "final stage does not COPY --from= an earlier build stage -- it should only bring in the built assets, not rebuild from source"
pass "final stage copies build output from an earlier stage"

deps_reinstalled=$(echo "$FINAL_STAGE" | grep -i 'npm install' | grep -v -- '-g')
[ -n "$deps_reinstalled" ] \
  && fail "final stage still runs npm install -- that belongs only in the build stage (installing a global CLI tool like \`npm install -g serve\` is fine)"
echo "$FINAL_STAGE" | grep -qi 'npm run build' \
  && fail "final stage still runs npm run build -- that belongs only in the build stage"
echo "$FINAL_STAGE" | grep -qE 'COPY[[:space:]]+code/example-frontend' \
  && fail "final stage still copies the raw frontend source -- only the built assets should end up in the final image"
pass "final stage does not rebuild from the original source"

# Static check: the final stage must still switch to a non-root user (the
# 3.5 fix should not have been lost while restructuring into stages).
last_user=$(echo "$FINAL_STAGE" | grep -E '^\s*USER\s+' | tail -1 | awk '{print $2}')
[ -n "$last_user" ] || fail "final stage has no USER instruction -- it still runs as root"
case "$last_user" in
  root | 0 | 0:0 | root:root)
    fail "final stage's USER instruction switches to root ($last_user)"
    ;;
esac
pass "final stage switches to non-root user ($last_user)"

# The exercise allows swapping out `serve` for something else, so the
# frontend's own container-side port is read from its Dockerfile rather than
# assumed -- prefer an EXPOSE instruction (works regardless of which static
# file server is used), falling back to serve's own "-l <port>" CMD argument
# for the common case of sticking with serve without adding EXPOSE.
frontend_container_port() {
  local port
  port=$(grep -E '^\s*EXPOSE\s+[0-9]+' "$1" | tail -1 | grep -oE '[0-9]+')
  if [ -z "$port" ]; then
    port=$(grep -oE '"-l"[[:space:]]*,[[:space:]]*"[0-9]+"' "$1" | grep -oE '[0-9]+' | tail -1)
  fi
  echo "$port"
}
FRONTEND_CONTAINER_PORT="$(frontend_container_port "$FRONTEND_DOCKERFILE")"
[ -n "$FRONTEND_CONTAINER_PORT" ] \
  || fail "could not determine the frontend's container port from 3_89/Dockerfile.frontend -- declare it via EXPOSE, or keep using serve's \"-l <port>\" argument"
pass "frontend's container port is $FRONTEND_CONTAINER_PORT"

docker build -f "$FRONTEND_DOCKERFILE" -t "$FRONTEND_IMAGE" "$REPO_ROOT" >/dev/null 2>&1 \
  || fail "docker build failed for 3_89/Dockerfile.frontend"
pass "frontend image builds"

docker run -d --name "$FRONTEND_CONTAINER" -p "$FRONTEND_CONTAINER_PORT:$FRONTEND_CONTAINER_PORT" "$FRONTEND_IMAGE" >/dev/null 2>&1 \
  || fail "docker run failed for frontend"
pass "frontend container started"

wait_for_http() {
  local url="$1"
  for _ in $(seq 1 30); do
    curl -s --max-time 2 "$url" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}
wait_for_http "http://localhost:$FRONTEND_CONTAINER_PORT" \
  || fail "frontend never became reachable on port $FRONTEND_CONTAINER_PORT"
pass "frontend is reachable"

docker rm -f "$FRONTEND_CONTAINER" >/dev/null 2>&1
pass "container cleaned up"

echo "All tests passed"
