#!/usr/bin/env bash
# Verifies exercise 3.6: 3_6/Dockerfile.frontend and 3_6/Dockerfile.backend
# are an optimized version of the 3.5 Dockerfiles -- same base images
# (ubuntu for the frontend, ubuntu or golang for the backend), the frontend's
# RUN instructions joined into one, and useless files dropped from the final
# image (the frontend's src folder, the backend's cache folder). Functional
# correctness is then checked the same way a student would check it -- by
# wiring the two containers together and pressing the "backend" exercise
# button in the frontend with a real browser (Playwright) and waiting for it
# to report success.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="$REPO_ROOT/3_6"
BACKEND_DOCKERFILE="$TARGET_DIR/Dockerfile.backend"
FRONTEND_DOCKERFILE="$TARGET_DIR/Dockerfile.frontend"
PLAYWRIGHT_DIR="$REPO_ROOT/tests/playwright"

BACKEND_IMAGE="dod-3-6-backend:test"
FRONTEND_IMAGE="dod-3-6-frontend:test"
BACKEND_CONTAINER="dod-3-6-backend-test"
FRONTEND_CONTAINER="dod-3-6-frontend-test"

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

[ -f "$BACKEND_DOCKERFILE" ] || fail "3_6/Dockerfile.backend not found"
[ -f "$FRONTEND_DOCKERFILE" ] || fail "3_6/Dockerfile.frontend not found"
pass "3_6/Dockerfile.backend and 3_6/Dockerfile.frontend exist"

# The exercise says to keep the base images as they were: ubuntu for the
# frontend, and either ubuntu or golang for the backend.
first_from() {
  grep -m1 -E '^\s*FROM\s+' "$1" | awk '{print $2}'
}
frontend_base="$(first_from "$FRONTEND_DOCKERFILE")"
case "$frontend_base" in
  ubuntu | ubuntu:*) pass "frontend Dockerfile still uses ubuntu as its base image ($frontend_base)" ;;
  *) fail "frontend Dockerfile's base image changed to '$frontend_base' -- it must stay ubuntu" ;;
esac
backend_base="$(first_from "$BACKEND_DOCKERFILE")"
case "$backend_base" in
  golang | golang:* | ubuntu | ubuntu:*) pass "backend Dockerfile still uses ubuntu/golang as its base image ($backend_base)" ;;
  *) fail "backend Dockerfile's base image changed to '$backend_base' -- it must stay ubuntu or golang" ;;
esac

# The frontend had 8 separate RUN instructions in 3.5 (apt update, apt
# install curl, the nodesource setup script, apt install nodejs, npm
# install, npm run build, npm install -g serve, useradd) -- joining them
# into a single RUN instruction is exactly what this exercise asks for.
run_count() {
  grep -cE '^\s*RUN\s' "$1"
}
frontend_runs=$(run_count "$FRONTEND_DOCKERFILE")
[ "$frontend_runs" -eq 1 ] \
  || fail "frontend Dockerfile has $frontend_runs RUN instructions -- join them all into a single RUN"
pass "frontend Dockerfile's RUN instructions were joined into one"

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

docker build -f "$BACKEND_DOCKERFILE" -t "$BACKEND_IMAGE" "$REPO_ROOT" >/dev/null 2>&1 \
  || fail "docker build failed for 3_6/Dockerfile.backend"
pass "backend image builds"

docker build -f "$FRONTEND_DOCKERFILE" -t "$FRONTEND_IMAGE" "$REPO_ROOT" >/dev/null 2>&1 \
  || fail "docker build failed for 3_6/Dockerfile.frontend"
pass "frontend image builds"

# The hints call out specific folders that should no longer be in the final
# image: the frontend's src folder (only the built static files are served)
# and the backend's cache folder.
docker run --rm "$FRONTEND_IMAGE" test -d /myapp/src >/dev/null 2>&1 \
  && fail "frontend image still contains the src folder -- only the build output is needed at runtime"
pass "frontend image no longer contains the src folder"

docker run --rm "$BACKEND_IMAGE" test -d /myproject/cache >/dev/null 2>&1 \
  && fail "backend image still contains the cache folder -- it is not needed at runtime"
pass "backend image no longer contains the cache folder"

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

# Regression check: the non-root user from exercise 3.5 should not have been
# lost while joining/reshuffling the RUN instructions.
check_running_as_non_root() {
  local container="$1"
  local label="$2"
  local uid
  uid=$(docker exec "$container" id -u 2>/dev/null) || fail "could not run 'id -u' inside the $label container"
  [ "$uid" != "0" ] || fail "$label container is running as root (uid 0) -- the 3.5 non-root fix regressed"
  pass "$label container is still running as non-root (uid $uid)"
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
