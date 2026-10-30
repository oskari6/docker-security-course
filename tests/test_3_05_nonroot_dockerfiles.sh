#!/usr/bin/env bash
# Verifies exercise 3.5: the example frontend and backend containers
# (3_5/Dockerfile.frontend, 3_5/Dockerfile.backend) run their process as a
# non-root user instead of root. Checked both statically (the Dockerfile
# actually switches user) and at runtime (the running container's process
# really is non-root, in case something later in the Dockerfile silently
# switches back to root). Functional correctness is then checked the same
# way a student would check it -- by wiring the two containers together and
# pressing the "backend" exercise button in the frontend with a real browser
# (Playwright) and waiting for it to report success.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="$REPO_ROOT/3_5"
BACKEND_DOCKERFILE="$TARGET_DIR/Dockerfile.backend"
FRONTEND_DOCKERFILE="$TARGET_DIR/Dockerfile.frontend"
PLAYWRIGHT_DIR="$REPO_ROOT/tests/playwright"

BACKEND_IMAGE="dod-3-5-backend:test"
FRONTEND_IMAGE="dod-3-5-frontend:test"
BACKEND_CONTAINER="dod-3-5-backend-test"
FRONTEND_CONTAINER="dod-3-5-frontend-test"

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

[ -f "$BACKEND_DOCKERFILE" ] || fail "3_5/Dockerfile.backend not found"
[ -f "$FRONTEND_DOCKERFILE" ] || fail "3_5/Dockerfile.frontend not found"
pass "3_5/Dockerfile.backend and 3_5/Dockerfile.frontend exist"

# Static check: the last USER instruction in each Dockerfile must switch to
# something other than root, instead of leaving/putting the process on root
# (the default if no USER instruction is present at all).
check_non_root_user() {
  local dockerfile="$1"
  local label="$2"
  local last_user
  last_user=$(grep -E '^\s*USER\s+' "$dockerfile" | tail -1 | awk '{print $2}')
  [ -n "$last_user" ] || fail "$label Dockerfile has no USER instruction -- it still runs as root"
  case "$last_user" in
    root | 0 | 0:0 | root:root)
      fail "$label Dockerfile's USER instruction switches to root ($last_user)"
      ;;
  esac
  pass "$label Dockerfile switches to non-root user ($last_user)"
}
check_non_root_user "$BACKEND_DOCKERFILE" "backend"
check_non_root_user "$FRONTEND_DOCKERFILE" "frontend"

# Read the frontend's serve port from its own Dockerfile (the "-l <port>"
# argument to `serve`) instead of assuming it's 5001 -- exercises are free to
# change it.
frontend_port() {
  grep -oE '"-l"[[:space:]]*,[[:space:]]*"[0-9]+"' "$1" | grep -oE '[0-9]+' | tail -1
}
FRONTEND_PORT="$(frontend_port "$FRONTEND_DOCKERFILE")"
[ -n "$FRONTEND_PORT" ] \
  || fail "could not find the frontend's serve port (a \"-l\", \"<port>\" argument) in $(basename "$FRONTEND_DOCKERFILE")'s CMD"
pass "frontend serves on port $FRONTEND_PORT (read from its Dockerfile)"

# The Dockerfiles COPY the example app source from ../code/example-backend
# and ../code/example-frontend relative to the repo root, so the build
# context has to be the repo root itself (with -f pointing at the Dockerfile
# under 3_5/), not the 3_5 directory.
docker build -f "$BACKEND_DOCKERFILE" -t "$BACKEND_IMAGE" "$REPO_ROOT" >/dev/null 2>&1 \
  || fail "docker build failed for 3_5/Dockerfile.backend"
pass "backend image builds"

docker build -f "$FRONTEND_DOCKERFILE" -t "$FRONTEND_IMAGE" "$REPO_ROOT" >/dev/null 2>&1 \
  || fail "docker build failed for 3_5/Dockerfile.frontend"
pass "frontend image builds"

# Run both containers with their ports published directly to the host, the
# same layout the Dockerfiles' baked-in REQUEST_ORIGIN/REACT_APP_BACKEND_URL
# values assume (the frontend talks to the backend via http://localhost:8080
# straight from the browser, not through a container network).
docker run -d --name "$BACKEND_CONTAINER" -p 8080:8080 "$BACKEND_IMAGE" >/dev/null 2>&1 \
  || fail "docker run failed for backend"
docker run -d --name "$FRONTEND_CONTAINER" -p "$FRONTEND_PORT:$FRONTEND_PORT" "$FRONTEND_IMAGE" >/dev/null 2>&1 \
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
wait_for_http "http://localhost:8080" || fail "backend never became reachable on port 8080"
wait_for_http "http://localhost:$FRONTEND_PORT" || fail "frontend never became reachable on port $FRONTEND_PORT"
pass "backend and frontend are reachable"

# Runtime check: confirm the process inside each running container is
# actually executing as a non-root user, not just that the Dockerfile
# contains a USER instruction somewhere.
check_running_as_non_root() {
  local container="$1"
  local label="$2"
  local uid
  uid=$(docker exec "$container" id -u 2>/dev/null) || fail "could not run 'id -u' inside the $label container"
  [ "$uid" != "0" ] || fail "$label container is running as root (uid 0) at runtime"
  pass "$label container is running as non-root (uid $uid) at runtime"
}
check_running_as_non_root "$BACKEND_CONTAINER" "backend"
check_running_as_non_root "$FRONTEND_CONTAINER" "frontend"

# Press the "backend" exercise button in the actual UI and check that it
# reports success, instead of calling the backend API directly.
command -v node >/dev/null 2>&1 || fail "node is required to run the browser check in tests/playwright"
(cd "$PLAYWRIGHT_DIR" && npm install --no-audit --no-fund >/dev/null 2>&1) \
  || fail "npm install failed in tests/playwright"
(cd "$PLAYWRIGHT_DIR" && npx --yes playwright install --with-deps chromium >/dev/null 2>&1) \
  || fail "playwright chromium install failed"

node "$PLAYWRIGHT_DIR/check-exercise-button.mjs" "http://localhost:$FRONTEND_PORT" backend \
  || fail "pressing the \"backend\" button in the frontend did not report success"
pass "pressing the \"backend\" button in the frontend reported success"

docker rm -f "$BACKEND_CONTAINER" "$FRONTEND_CONTAINER" >/dev/null 2>&1
pass "containers cleaned up"

echo "All tests passed"
