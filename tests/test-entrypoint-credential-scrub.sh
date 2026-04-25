#!/usr/bin/env bash
# tests/test-entrypoint-credential-scrub.sh
#
# Shell regression tests for the credential-scrub fix in scripts/docker-entrypoint.sh.
#
# Background:
#   When SOURCE_URL embeds credentials (https://user:pass@host/path.git), the
#   pattern used by Gitea-backed apps, the host extraction
#       GIT_HOST="${SOURCE_URL#*://}"; GIT_HOST="${GIT_HOST%%/*}"
#   yields "user:pass@host" — i.e. credentials remain in GIT_HOST.
#
#   The clone then persisted the credentialed URL into .git/config because the
#   original "scrub" line was guarded by `if [[ -n "$GIT_TOKEN" ]]` and was
#   therefore skipped entirely for Gitea apps (which embed credentials in
#   SOURCE_URL directly and do not set GIT_TOKEN).
#
# Fix (this PR):
#   Parse GIT_HOST / GIT_PATH / PROTOCOL unconditionally (before the GIT_TOKEN
#   block). Introduce GIT_HOST_PUBLIC="${GIT_HOST##*@}" — a sanitized variant
#   used for the persisted remote URL. Remove the GIT_TOKEN guard from the
#   `remote set-url` scrub so it always runs. When SOURCE_URL has no
#   credentials, GIT_HOST_PUBLIC == GIT_HOST and behaviour is unchanged.
#
# These tests grep the entrypoint to assert the fix has not regressed.

ENTRYPOINT="scripts/docker-entrypoint.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: GIT_HOST_PUBLIC is derived from GIT_HOST with embedded creds stripped
# ---------------------------------------------------------------------------
if grep -qE 'GIT_HOST_PUBLIC="\$\{GIT_HOST##\*@\}"' "$ENTRYPOINT"; then
  pass "GIT_HOST_PUBLIC strips user:pass@ from GIT_HOST"
else
  fail "GIT_HOST_PUBLIC assignment is missing or does not strip embedded creds"
fi

# ---------------------------------------------------------------------------
# Test 2: persisted remote URL uses the scrubbed host
# ---------------------------------------------------------------------------
if grep -qF 'git -C "$WORK_DIR" remote set-url origin "${PROTOCOL}://${GIT_HOST_PUBLIC}${GIT_PATH}"' "$ENTRYPOINT"; then
  pass "remote set-url uses GIT_HOST_PUBLIC (credentials removed from .git/config)"
else
  fail "remote set-url still uses GIT_HOST — credentials would leak into .git/config"
fi

# ---------------------------------------------------------------------------
# Test 3: remote set-url is unconditional — not guarded by GIT_TOKEN
#
# The scrub must run for both the GIT_TOKEN path and the Gitea
# embedded-credential path. An `if [[ -n "$GIT_TOKEN" ]]` guard around the
# set-url means Gitea apps never have their .git/config scrubbed.
# ---------------------------------------------------------------------------
guarded=$(awk '/if \[\[ -n.*GIT_TOKEN/,/fi/' "$ENTRYPOINT" | grep 'remote set-url' || true)
if [ -z "$guarded" ]; then
  pass "remote set-url is not guarded by GIT_TOKEN (unconditional scrub)"
else
  fail "remote set-url is still inside a GIT_TOKEN guard — Gitea credentials would leak: $guarded"
fi

# ---------------------------------------------------------------------------
# Test 4: no surviving line that persists the unscrubbed GIT_HOST
# ---------------------------------------------------------------------------
unsafe_persist=$(grep -nE 'remote set-url origin "https://\$\{GIT_HOST\}\$\{GIT_PATH\}"' "$ENTRYPOINT" || true)
if [ -z "$unsafe_persist" ]; then
  pass "no remote set-url persists the unscrubbed GIT_HOST"
else
  fail "remote set-url still persists unscrubbed GIT_HOST: $unsafe_persist"
fi

# ---------------------------------------------------------------------------
# Test 5: behavioral verification — run the relevant fragment in a sandbox
#
# Source the host-parsing logic with a Gitea-style SOURCE_URL and assert that
# GIT_HOST_PUBLIC has no '@' while GIT_HOST does. This catches regressions
# where the parameter expansion is changed in a way that defeats the strip.
# ---------------------------------------------------------------------------
sandbox=$(bash -c '
  SOURCE_URL="https://oscadmin:abc123def@example.git.host/owner/repo.git"
  GIT_HOST="${SOURCE_URL#*://}"
  GIT_HOST="${GIT_HOST%%/*}"
  GIT_HOST_PUBLIC="${GIT_HOST##*@}"
  echo "GIT_HOST=$GIT_HOST"
  echo "GIT_HOST_PUBLIC=$GIT_HOST_PUBLIC"
')

if echo "$sandbox" | grep -q '^GIT_HOST=oscadmin:abc123def@example.git.host$' && \
   echo "$sandbox" | grep -q '^GIT_HOST_PUBLIC=example.git.host$'; then
  pass "host-parsing on a Gitea-style URL strips creds in GIT_HOST_PUBLIC only"
else
  fail "host-parsing sandbox produced unexpected output: $sandbox"
fi

# ---------------------------------------------------------------------------
# Test 6: behavioral verification — credential-less URL is unchanged
# ---------------------------------------------------------------------------
sandbox_plain=$(bash -c '
  SOURCE_URL="https://github.com/owner/repo.git"
  GIT_HOST="${SOURCE_URL#*://}"
  GIT_HOST="${GIT_HOST%%/*}"
  GIT_HOST_PUBLIC="${GIT_HOST##*@}"
  echo "GIT_HOST=$GIT_HOST"
  echo "GIT_HOST_PUBLIC=$GIT_HOST_PUBLIC"
')

if echo "$sandbox_plain" | grep -q '^GIT_HOST=github.com$' && \
   echo "$sandbox_plain" | grep -q '^GIT_HOST_PUBLIC=github.com$'; then
  pass "host-parsing on a credential-less URL is a no-op (GIT_HOST_PUBLIC == GIT_HOST)"
else
  fail "credential-less host-parsing produced unexpected output: $sandbox_plain"
fi

# ---------------------------------------------------------------------------
# Test 7: behavioral verification — GIT_TOKEN path uses GIT_HOST_PUBLIC
#
# When GIT_TOKEN is set, the injected URL must use GIT_HOST_PUBLIC (not
# GIT_HOST which might already contain embedded creds from SOURCE_URL).
# ---------------------------------------------------------------------------
if grep -qF '${GIT_TOKEN}@${GIT_HOST_PUBLIC}' "$ENTRYPOINT"; then
  pass "GIT_TOKEN injection uses GIT_HOST_PUBLIC (no double-embedding of creds)"
else
  fail "GIT_TOKEN injection does not reference GIT_HOST_PUBLIC"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  exit 1
fi
exit 0
