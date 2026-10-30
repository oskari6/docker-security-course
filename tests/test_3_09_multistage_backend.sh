#!/usr/bin/env bash
# Verifies exercise 3.9: 3_89/Dockerfile.backend is a genuine multi-stage
# build -- a build stage that compiles the Go binary, and a separate final
# stage built FROM scratch that only contains that compiled binary (via
# COPY --from=<build stage>), not the Go toolchain or the original source.
# Functional correctness is then checked together with the multi-stage
# frontend from exercise 3.8 (3_89/Dockerfile.frontend) -- by wiring the two
# containers together and pressing the "backend" exercise button in the
# frontend with a real browser (Playwright) and waiting for it to report
# success.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DOCKERFILE="$REPO_ROOT/3_89/Dockerfile.backend"
FRONTEND_DOCKERFILE="$REPO_ROOT/3_89/Dockerfile.frontend"
PLAYWRIGHT_DIR="$REPO_ROOT/tests/playwright"

BACKEND_IMAGE="dod-3-9-backend:test"
FRONTEND_IMAGE="dod-3-9-frontend:test"
BACKEND_CONTAINER="dod-3-9-backend-test"
FRONTEND_CONTAINER="dod-3-9-frontend-test"
BACKEND_PORT=8080

fail() {
  echo "FAIL: $1"
  exit 1
}

pass() {
  echo "PASS: $1"
}

cleanup() {
  docker rm -f "$BACKEND_CONTAINER" "$FRONTEND_CONTAINER" >/dev/null 2>&1
}
trap cleanup EXIT

[ -f "$BACKEND_DOCKERFILE" ] || fail "3_89/Dockerfile.backend not found"
[ -f "$FRONTEND_DOCKERFILE" ] || fail "3_89/Dockerfile.frontend (the 3.8 multi-stage frontend) not found"
pass "3_89/Dockerfile.backend and 3_89/Dockerfile.frontend exist"

# Must actually be multi-stage: more than one FROM instruction.
from_count=$(grep -cE '^\s*FROM\s+' "$BACKEND_DOCKERFILE")
[ "$from_count" -ge 2 ] \
  || fail "Dockerfile.backend has only $from_count FROM instruction(s) -- use a genuine multi-stage build (a build stage + a scratch final stage)"
pass "Dockerfile.backend is multi-stage ($from_count FROM instructions)"

# The final stage must be FROM scratch, as the exercise asks for.
final_from=$(grep -E '^\s*FROM\s+' "$BACKEND_DOCKERFILE" | tail -1 | awk '{print $2}')
[ "$(echo "$final_from" | tr '[:upper:]' '[:lower:]')" = "scratch" ] \
  || fail "final stage is 'FROM $final_from', not 'FROM scratch'"
pass "final stage is FROM scratch"

# Everything from the last FROM instruction onward is the final stage --
# that's what ends up in the shipped image.
final_stage() {
  awk 'BEGIN{s=0} /^[[:space:]]*FROM[[:space:]]/{s=NR} {a[NR]=$0} END{for(i=s;i<=NR;i++) print a[i]}' "$1"
}
FINAL_STAGE="$(final_stage "$BACKEND_DOCKERFILE")"

echo "$FINAL_STAGE" | grep -q -- '--from=' \
  || fail "final stage does not COPY --from= an earlier build stage -- it should only bring in the compiled binary, not rebuild from source"
pass "final stage copies the compiled binary from an earlier stage"

echo "$FINAL_STAGE" | grep -qi 'go build' \
  && fail "final stage still runs go build -- that belongs only in the build stage (scratch has no Go toolchain to run it with anyway)"
echo "$FINAL_STAGE" | grep -qE 'COPY[[:space:]]+code/example-backend' \
  && fail "final stage still copies the raw backend source -- only the compiled binary should end up in the final image"
pass "final stage does not rebuild from the original source"

docker build -f "$BACKEND_DOCKERFILE" -t "$BACKEND_IMAGE" "$REPO_ROOT" >/dev/null 2>&1 \
  || fail "docker build failed for 3_89/Dockerfile.backend"
pass "backend image builds"

docker build -f "$FRONTEND_DOCKERFILE" -t "$FRONTEND_IMAGE" "$REPO_ROOT" >/dev/null 2>&1 \
  || fail "docker build failed for 3_89/Dockerfile.frontend"
pass "frontend image builds"

# The frontend may use any static file server (exercise 3.8 allows swapping
# out serve), so read its container port from EXPOSE, falling back to
# serve's own "-l <port>" CMD argument.
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

# The backend only accepts CORS requests from the origin baked into its
# REQUEST_ORIGIN env var, so the frontend has to be published on that exact
# host port, whatever it is, rather than an assumed one.
backend_cors_port() {
  grep -oE 'REQUEST_ORIGIN=http://localhost:[0-9]+' "$1" | grep -oE '[0-9]+$' | tail -1
}
FRONTEND_HOST_PORT="$(backend_cors_port "$BACKEND_DOCKERFILE")"
[ -n "$FRONTEND_HOST_PORT" ] \
  || fail "could not read the expected frontend origin port from 3_89/Dockerfile.backend's REQUEST_ORIGIN"
pass "frontend will be published on port $FRONTEND_HOST_PORT (matching the backend's REQUEST_ORIGIN), container listens on $FRONTEND_CONTAINER_PORT"

docker run -d --name "$BACKEND_CONTAINER" -p "$BACKEND_PORT:$BACKEND_PORT" "$BACKEND_IMAGE" >/dev/null 2>&1 \
  || fail "docker run failed for backend"

# A binary that isn't fully static (e.g. CGO_ENABLED not disabled) will fail
# to even start in a scratch image -- catch that here with a clear message
# instead of waiting out the full reachability timeout below.
sleep 1
[ "$(docker inspect --format='{{.State.Running}}' "$BACKEND_CONTAINER" 2>/dev/null)" = "true" ] \
  || fail "backend container exited immediately -- the binary likely isn't statically linked (build with CGO_ENABLED=0)"

docker run -d --name "$FRONTEND_CONTAINER" -p "$FRONTEND_HOST_PORT:$FRONTEND_CONTAINER_PORT" "$FRONTEND_IMAGE" >/dev/null 2>&1 \
  || fail "docker run failed for frontend"
pass "backend and frontend containers started"

wait_for_http() {
  local url="$1"
  for _ in $(seq 1 30); do
    curl -s --max-time 2 "$url" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}
wait_for_http "http://localhost:$BACKEND_PORT" || fail "backend never became reachable on port $BACKEND_PORT"
wait_for_http "http://localhost:$FRONTEND_HOST_PORT" || fail "frontend never became reachable on port $FRONTEND_HOST_PORT"
pass "backend and frontend are reachable"

# Press the "backend" exercise button in the actual UI and check that it
# reports success, instead of calling the backend API directly.
command -v node >/dev/null 2>&1 || fail "node is required to run the browser check in tests/playwright"
(cd "$PLAYWRIGHT_DIR" && npm install --no-audit --no-fund >/dev/null 2>&1) \
  || fail "npm install failed in tests/playwright"
(cd "$PLAYWRIGHT_DIR" && npx --yes playwright install --with-deps chromium >/dev/null 2>&1) \
  || fail "playwright chromium install failed"

node "$PLAYWRIGHT_DIR/check-exercise-button.mjs" "http://localhost:$FRONTEND_HOST_PORT" backend \
  || fail "pressing the \"backend\" button in the frontend did not report success"
pass "pressing the \"backend\" button in the frontend reported success"

docker rm -f "$BACKEND_CONTAINER" "$FRONTEND_CONTAINER" >/dev/null 2>&1
pass "containers cleaned up"

echo "All tests passed"
