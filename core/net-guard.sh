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
# What it does buy: the one combination that should never happen is an agent
# running unattended with a network tool available. Then nobody is reading the
# warning that airlock-warn.sh injected at session start, so refuse instead of
# warn.
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

MODE=$(cat "$MODE_FILE" 2>/dev/null || echo unknown)

# jq is not guaranteed in every preset's image, so fall back to a text match.
# The grep form takes the FIRST occurrence, which is why jq is preferred: JSON
# does not guarantee key order, and tool_input can contain arbitrary text.
if command -v jq >/dev/null 2>&1; then
  PERM=$(printf '%s' "$INPUT" | jq -r '.permission_mode // empty' 2>/dev/null || true)
  TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
else
  FLAT=$(printf '%s' "$INPUT" | tr -d ' \n')
  PERM=$(printf '%s' "$FLAT" | grep -o '"permission_mode":"[A-Za-z]*"' | head -1 | cut -d'"' -f4 || true)
  TOOL=$(printf '%s' "$FLAT" | grep -o '"tool_name":"[A-Za-z]*"'       | head -1 | cut -d'"' -f4 || true)
fi

# WebFetch while closed needs no guard: the firewall already refuses the
# connection, and staying silent keeps the hook off the hot path.
#
# WebSearch is NOT covered by that reasoning and must not take this exit. It
# executes server-side and its results arrive over the api.anthropic.com channel,
# which init-firewall.sh permits as `required` in BOTH modes — so iptables never
# sees it. Measured, not assumed: with the airlock closed, WebFetch(github.com)
# returned ECONNREFUSED while WebSearch returned snippets from four external
# sites. Closed mode was therefore the *more* permissive state for search, which
# inverts the design's intent — search results are attacker-influenceable text,
# and that is injection surface whatever the airlock is doing.
#
# An unreadable tool_name takes the guarded path, matching the fail-closed rule
# below.
if [ "$MODE" != "open" ] && [ "$TOOL" = "WebFetch" ]; then
  exit 0
fi

# Allowlist the attended modes rather than denylisting the unattended ones. The
# denylist form (bypassPermissions|dontAsk|auto) silently permitted anything it
# did not recognise, so a mode added or renamed by a future Claude Code release
# would have opened this up with no sign. Unknown now denies, like an
# undeterminable one always has.
case "$PERM" in
  default|plan|acceptEdits) exit 0 ;;
  "") deny "REFUSED: this hook could not determine the session's permission mode, so it is failing closed. Network tools are refused in unattended sessions. Tell the user to retry in an interactive session, and if the airlock is open, to run 'ccnet close' on the host." ;;
esac

deny "REFUSED: this session is running unattended and no one is watching it. Network tools are the channel an injected instruction reaches for first, and their content is attacker-influenceable regardless of the airlock: WebSearch results arrive over the Anthropic API even while the airlock is closed. Stop and tell the user to retry in an interactive session, or - if the airlock is open - to run 'ccnet close' on the host first. Do not attempt the same request through Bash instead."
