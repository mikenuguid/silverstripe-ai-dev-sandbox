#!/bin/bash
# ai-dev-sandbox — network airlock.
#
# CORE FILE. Identical in every project; do not edit per project. Everything
# project-specific comes from /etc/sandbox-allowlist, baked into the image.
#
# Modelled on anthropics/claude-code/.devcontainer/init-firewall.sh, with the
# four stock openings closed:
#   1. blanket outbound TCP/22 to any host          -> removed
#   2. outbound UDP/53 to any resolver              -> pinned to Docker's resolver
#   3. every GitHub CIDR from /meta                 -> named hosts only
#   4. the whole Docker bridge subnet (OUTPUT)      -> narrowed to declared services
#
# Behaviour is driven by /etc/claude-net-mode, root-owned and NOT writable by the
# sandbox user. Re-running this script re-applies the CURRENT mode; it can never
# widen the allowlist. That is why it is safe to grant via sudo.
#
# Failure handling: a transient DNS failure must never leave the mode file
# claiming "open" while the rules say otherwise. Any abort forces the mode to
# closed and retries once; a second failure leaves everything blocked.
set -euo pipefail
IFS=$'\n\t'

MODE_FILE=/etc/claude-net-mode
ALLOWLIST=/etc/sandbox-allowlist
RECOVERY="${FIREWALL_RECOVERY:-0}"

fail_closed() {
    local rc=$?
    [ "$rc" -eq 0 ] && return 0
    echo "ERROR: firewall setup failed (exit $rc)"
    # Flush before setting the policy. Policy DROP alone is not enough: an
    # explicit ACCEPT rule already added earlier in the run beats it, so the
    # "all outbound traffic is blocked" message below would be a lie.
    iptables -F 2>/dev/null || true
    ipset destroy allowed-domains 2>/dev/null || true
    iptables -P INPUT DROP  2>/dev/null || true
    iptables -P OUTPUT DROP 2>/dev/null || true
    iptables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
    iptables -A INPUT  -i lo -j ACCEPT 2>/dev/null || true
    if [ "$RECOVERY" = "1" ]; then
        echo "FATAL: recovery attempt also failed. All outbound traffic is blocked."
        exit "$rc"
    fi
    echo "Forcing mode to CLOSED and retrying once so the state file matches reality..."
    echo closed > "$MODE_FILE"
    FIREWALL_RECOVERY=1 exec "$0"
}
trap fail_closed EXIT

MODE=$(cat "$MODE_FILE" 2>/dev/null || echo closed)
echo "Applying firewall in mode: $MODE"

# --- Parse the allowlist -----------------------------------------------------
# Format, one entry per line, '#' comments and blanks ignored:
#   example.com          a domain, reachable only when OPEN
#   tcp:db:3306          an internal service, reachable in BOTH modes
DOMAINS=()
SERVICES=()
if [ -r "$ALLOWLIST" ]; then
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(echo "$line" | tr -d '[:space:]')"
        [ -z "$line" ] && continue
        case "$line" in
            tcp:*) SERVICES+=("$line") ;;
            *)     DOMAINS+=("$line") ;;
        esac
    done < "$ALLOWLIST"
fi

# Preserve Docker's internal DNS NAT rules before flushing.
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# Deterministic starting point. Flushing rules does NOT reset policies, so set
# them explicitly — and to DROP, not ACCEPT, so there is no window in which the
# network is briefly wide open while this script runs.
iptables -P INPUT DROP
iptables -P OUTPUT DROP
iptables -P FORWARD DROP

# IPv6. The allowlist is IPv4-only (ipset hash:net, A records), so the only safe
# posture is to block v6 entirely apart from loopback. Without this, a daemon or
# compose network with IPv6 enabled would give unrestricted v6 egress while the
# mode file read "closed" and ccnet status — which inspects only iptables —
# reported "(enforced)".
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -F 2>/dev/null || true
    ip6tables -P INPUT DROP 2>/dev/null || true
    ip6tables -P OUTPUT DROP 2>/dev/null || true
    ip6tables -P FORWARD DROP 2>/dev/null || true
    ip6tables -A INPUT  -i lo -j ACCEPT 2>/dev/null || true
    ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
fi

if [ -n "$DOCKER_DNS_RULES" ]; then
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
fi

iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# --- Hole #2 closed: DNS only to Docker's embedded resolver ------------------
# Added before resolution, since the policy above is already DROP.
iptables -A OUTPUT -p udp -d 127.0.0.11 --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp -d 127.0.0.11 --dport 53 -j ACCEPT

# --- Hole #1 closed: no blanket port 22 rule at all --------------------------

ipset create allowed-domains hash:net

resolve_into_ipset() {
    local domain="$1" required="${2:-optional}" attempt ips all_ips="" count

    # Resolve several times and take the union. CDN-backed hosts hand back a
    # different edge IP on each lookup, so an ipset built from one answer is
    # stale within minutes — connections then hit REJECT and downloads fail
    # with "Operation not permitted".
    for attempt in 1 2 3; do
        ips=$(dig +short A "$domain" 2>/dev/null \
              | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
        [ -n "$ips" ] && all_ips=$(printf '%s\n%s' "$all_ips" "$ips")
        # No sleep after the final attempt — it delayed every start and every
        # ccnet open/close by a second per domain for nothing.
        [ "$attempt" -lt 3 ] && sleep 1
    done
    all_ips=$(echo "$all_ips" | grep -E '^[0-9.]+$' | sort -u || true)

    if [ -z "$all_ips" ]; then
        if [ "$required" = "required" ]; then
            echo "  FAILED  $domain (required)"
            return 1
        fi
        echo "  WARNING $domain did not resolve — it will be unreachable"
        return 0
    fi

    count=0
    while read -r ip; do
        ipset add allowed-domains "$ip" 2>/dev/null || true
        # Also allow the containing /24. Union-of-lookups still loses to
        # rotation over a long session; exact-IP allowlisting does not hold for
        # CDNs.
        #
        # TRADE-OFF: a /24 of a CDN edge may host unrelated tenants, so this is
        # wider than the domain you asked for. Acceptable because the primary
        # control is the airlock — this list is live only during windows you
        # deliberately open. Tight domain filtering needs a filtering proxy.
        ipset add allowed-domains "$(echo "$ip" | sed 's/\.[0-9]*$/.0\/24/')" 2>/dev/null || true
        count=$((count + 1))
    done <<< "$all_ips"

    echo "  ok      $domain ($count addr, /24 expanded)"
    return 0
}

# Claude cannot run without this one, so it is the only hard requirement and is
# never listed in the project allowlist.
resolve_into_ipset "api.anthropic.com" required

GITHUB_LISTED=0
if [ "$MODE" != "closed" ]; then
    for domain in ${DOMAINS+"${DOMAINS[@]}"}; do
        resolve_into_ipset "$domain"
        [ "$domain" = "github.com" ] && GITHUB_LISTED=1
    done
fi

# --- Hole #4 narrowed: declared internal services only -----------------------
# The stock rule allowed the entire Docker bridge subnet outbound. Deleting it
# outright would stop the app reaching its database, so scope it to the exact
# services the project declares.
#
# These apply in BOTH modes: an app must still reach its database while the
# airlock is closed. Entries are therefore validated to resolve to a private
# address — a public IP here would be a way to smuggle internet access into
# closed mode.
for entry in ${SERVICES+"${SERVICES[@]}"}; do
    svc_host="$(echo "$entry" | cut -d: -f2)"
    svc_port="$(echo "$entry" | cut -d: -f3)"
    if [ -z "$svc_host" ] || [ -z "$svc_port" ]; then
        echo "  WARNING malformed service entry '$entry' — expected tcp:host:port"
        continue
    fi
    svc_ips=$(getent hosts "$svc_host" | awk '{print $1}' || true)
    if [ -z "$svc_ips" ]; then
        echo "  WARNING could not resolve service '$svc_host' — it will be unreachable"
        continue
    fi
    while read -r svc_ip; do
        case "$svc_ip" in
            10.*|192.168.*|127.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
                echo "  ok      $svc_host at $svc_ip:$svc_port"
                iptables -A OUTPUT -p tcp -d "$svc_ip" --dport "$svc_port" -j ACCEPT
                ;;
            *)
                echo "  REFUSED $svc_host resolves to public address $svc_ip —"
                echo "          internal services must be private. Ignoring."
                ;;
        esac
    done <<< "$svc_ips"
done

# Inbound TCP, so the host can reach published ports.
#
# This was previously scoped to the bridge gateway's /24, which broke in two
# real configurations: with `"userland-proxy": false` the DNAT preserves the
# original source (127.0.0.1, or a LAN client's real IP), and Docker's default
# address pool hands out /16s rather than /24s. In both cases the packet fell
# through to the DROP policy and the site simply appeared dead.
#
# Accepting inbound TCP is safe here: this container sits on a private Docker
# network, so the only things that can reach it are the host and sibling
# containers. The control that matters is OUTPUT, which stays deny-by-default.
iptables -A INPUT -p tcp -m state --state NEW -j ACCEPT
# NOTE: deliberately no matching OUTPUT rule — that was hole #4.

iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Verifying..."

if curl --connect-timeout 5 -s https://example.com >/dev/null 2>&1; then
    echo "ERROR: example.com reachable — firewall did not apply"
    exit 1
fi
if ! curl --connect-timeout 5 -s https://api.anthropic.com >/dev/null 2>&1; then
    echo "ERROR: api.anthropic.com unreachable — Claude cannot run"
    exit 1
fi

if [ "$MODE" = "closed" ]; then
    if curl --connect-timeout 5 -s https://github.com >/dev/null 2>&1; then
        echo "ERROR: github.com reachable while CLOSED — airlock is not working"
        exit 1
    fi
    echo "Verified: CLOSED (Anthropic only)"
else
    # Only assert github if the project actually listed it; otherwise a project
    # with no GitHub access would fail its own start-up check.
    if [ "$GITHUB_LISTED" = "1" ] && ! curl --connect-timeout 5 -s https://github.com >/dev/null 2>&1; then
        echo "ERROR: github.com is allowlisted but unreachable while OPEN"
        exit 1
    fi
    echo "Verified: OPEN (allowlist active)"
fi
