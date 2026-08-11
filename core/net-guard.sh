#!/bin/bash
# ai-dev-sandbox — PreToolUse guard on the agent's network tools.
#
# CORE FILE, advisory only. This is a tripwire, NOT the boundary: it covers
# WebFetch and WebSearch and nothing else. Outbound traffic from Bash
# (composer install, git fetch, a test suite calling an API) is not matched, and
# must not be — those are exactly what an open airlock is for, and matching
# command strings for `curl` is trivially evaded anyway. The iptables airlock
# remains the control.
#
# What it does buy: the one combination that should never happen is an OPEN
# airlock plus an agent running unattended. Then nobody is reading the warning
# that airlock-warn.sh injected at session start, so refuse instead of warn.
#
# Attended sessions are left alone. `default` already prompts for WebFetch, so a
# second gate would be friction with no gain — and blocking network tools during
# a window the user deliberately opened is the opposite of useful.
#
# `deny` rather than `ask`: deny is deterministic and documented to block. Whether
# `ask` is auto-approved under --dangerously-skip-permissions is not something
# this file should depend on.
#
# NOT set -e: an unparseable payload must reach the fail-closed branch below
# rather than abort the hook, which would let the call through.
set -uo pipefail

MODE_FILE=/etc/claude-net-mode
INPUT=$(cat)          # the hook payload arrives on stdin

deny() {
  # Fixed strings only — nothing interpolated, so there is no JSON to escape.
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

# Closed is the normal state and needs no guard: the firewall already refuses
# these connections. Staying silent here keeps the hook off the hot path.
[ "$(cat "$MODE_FILE" 2>/dev/null || echo unknown)" = "open" ] || exit 0

# jq is not guaranteed in every preset's image, so fall back to a text match.
# The grep form takes the FIRST occurrence, which is why jq is preferred: JSON
# does not guarantee key order, and tool_input can contain arbitrary text.
if command -v jq >/dev/null 2>&1; then
  PERM=$(printf '%s' "$INPUT" | jq -r '.permission_mode // empty' 2>/dev/null || true)
else
  PERM=$(printf '%s' "$INPUT" | tr -d ' \n' \
         | grep -o '"permission_mode":"[A-Za-z]*"' | head -1 | cut -d'"' -f4 || true)
fi

case "$PERM" in
  bypassPermissions|dontAsk|auto)
    deny "REFUSED: the sandbox network airlock is OPEN and this session is running unattended. That combination is what the airlock exists to prevent - an open network is the exposure window that makes prompt injection worth attempting, and no one is watching this run. Stop and tell the user to run 'ccnet close' on the host, then retry. Do not attempt the same fetch through Bash instead."
    ;;
  "")
    # Fail closed, matching init-firewall.sh: if the state cannot be determined,
    # the safe reading is the dangerous one.
    deny "REFUSED: the sandbox network airlock is OPEN and this hook could not determine the session's permission mode, so it is failing closed. Tell the user to run 'ccnet close' on the host, or to retry in an interactive session."
    ;;
esac

# Attended (default, plan, acceptEdits): defer to the normal permission flow.
exit 0
