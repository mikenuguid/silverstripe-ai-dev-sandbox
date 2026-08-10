#!/bin/bash
# ai-dev-sandbox — open the airlock.
#
# CORE FILE. Root-only, and deliberately NOT in sudoers: this is meant to be
# invoked from the HOST via `docker exec -u root`, never from inside the
# container. If the sandboxed process could run this, the airlock would be
# decoration.
set -euo pipefail
echo open > /etc/claude-net-mode
/usr/local/bin/init-firewall.sh
conntrack -F 2>/dev/null || true
