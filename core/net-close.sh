#!/bin/bash
# ai-dev-sandbox — close the airlock.
#
# CORE FILE. Root-only, and deliberately NOT in sudoers. See net-open.sh.
#
# conntrack -F matters: the ESTABLISHED,RELATED rule means an already-open
# socket would otherwise survive the ipset change and keep working after close.
set -euo pipefail
echo closed > /etc/claude-net-mode
/usr/local/bin/init-firewall.sh
conntrack -F 2>/dev/null || true
