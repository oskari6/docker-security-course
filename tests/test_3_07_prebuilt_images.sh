#!/usr/bin/env bash
# Verifies exercise 3.7: 3_7/Dockerfile.frontend and 3_7/Dockerfile.backend
# switch from a generic base image (ubuntu, plain golang) to a smaller,
# preinstalled Alpine variant -- an Alpine Node.js image (version 16, the
# version the frontend actually needs) for the frontend, and an Alpine
# Golang image for the backend -- instead of manually apt-get/curl-installing
# Node.js on top of ubuntu. Functional correctness is then checked the same
# way a student would check it -- by wiring the two containers together and
# pressing the "backend" exercise button in the frontend with a real browser
# (Playwright) and waiting for it to report success.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="$REPO_ROOT/3_7"
BACKEND_DOCKERFILE="$TARGET_DIR/Dockerfile.backend"
FRONTEND_DOCKERFILE="$TARGET_DIR/Dockerfile.frontend"
PLAYWRIGHT_DIR="$REPO_ROOT/tests/playwright"

BACKEND_IMAGE="dod-3-7-backend:test"
FRONTEND_IMAGE="dod-3-7-frontend:test"
BACKEND_CONTAINER="dod-3-7-backend-test"
FRONTEND_CONTAINER="dod-3-7-frontend-test"

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

[ -f "$BACKEND_DOCKERFILE" ] || fail "3_7/Dockerfile.backend not found"
[ -f "$FRONTEND_DOCKERFILE" ] || fail "3_7/Dockerfile.frontend not found"
pass "3_7/Dockerfile.backend and 3_7/Dockerfile.frontend exist"

first_from() {
  grep -m1 -E '^\s*FROM\s+' "$1" | awk '{print $2}'
}

# The frontend must switch from ubuntu (+ a manual curl/nodesource Node.js
# install) to a preinstalled Node.js image -- specifically Node 16, since
# that's the version the app actually needs -- with an Alpine variant.
frontend_base="$(first_from "$FRONTEND_DOCKERFILE")"
case "$frontend_base" in
  node:16* )
    case "$frontend_base" in
      *alpine*) pass "frontend Dockerfile uses a preinstalled Node 16 Alpine image ($frontend_base)" ;;
      *) fail "frontend Dockerfile's base image ($frontend_base) is Node 16 but not an Alpine variant -- use the alpine tag" ;;
    esac
    ;;
  *) fail "frontend Dockerfile's base image is '$frontend_base' -- it must be a preinstalled Node 16 Alpine image (e.g. node:16-alpine)" ;;
esac

# The backend must switch from the plain golang image to its Alpine variant.
backend_base="$(first_from "$BACKEND_DOCKERFILE")"
case "$backend_base" in
  golang:*alpine*) pass "backend Dockerfile uses a preinstalled Golang Alpine image ($backend_base)" ;;
  *) fail "backend Dockerfile's base image is '$backend_base' -- it must be a preinstalled Golang Alpine image (e.g. golang:1.24-alpine)" ;;
esac

# With Node.js preinstalled there's no more reason to apt-get/curl it in --
# that manual install path should be gone from the Dockerfile.
grep -qiE 'apt(-get)?|nodesource' "$FRONTEND_DOCKERFILE" \
  && fail "frontend Dockerfile still manually installs packages via apt/nodesource -- Node.js now comes preinstalled from the base image"
pass "frontend Dockerfile no longer manually installs Node.js"

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
  || fail "docker build failed for 3_7/Dockerfile.backend"
pass "backend image builds"

docker build -f "$FRONTEND_DOCKERFILE" -t "$FRONTEND_IMAGE" "$REPO_ROOT" >/dev/null 2>&1 \
  || fail "docker build failed for 3_7/Dockerfile.frontend"
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

# Regression check: the non-root user from exercise 3.5 should not have been
# lost while switching base images.
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
# reports success, instead of calling the backend API directly -- this is
# what "make sure the application still works" means in practice.
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
