# How it works

Three layers, each independent:

| Layer | Stops |
|---|---|
| Container | Access to the host filesystem, your credentials, anything outside the project |
| Firewall + airlock | All network except an explicit allowlist; closed by default |
| Agent's own sandbox | Reads and writes to sensitive paths, as a second line inside |

Two constraints drive the design:

**"Closed" cannot mean *no* network.** The agent needs `api.anthropic.com`. A full
`docker network disconnect` kills it. Closed means the allowlist shrinks to Anthropic only.

**The toggle must sit outside the agent's reach.** Control lives on the host, over
`docker exec`, and the container has **no Docker socket**.

## The privilege model

The container has `NET_ADMIN`, so root inside it can rewrite the firewall. The whole boundary
therefore rests on the sandbox user not being root and not being able to become root:

```
$ sudo -n -l
User dev may run the following commands:
    (root) NOPASSWD: /usr/local/bin/init-firewall.sh
```

One command. And it is useless for escaping, because:

1. `init-firewall.sh` is root-owned `0755` — executable, not editable
2. `/etc/claude-net-mode` is root-owned `0644` — readable, not writable
3. The script reads its mode from that file at runtime

So the only privileged action available re-applies whatever mode is already set. It is
idempotent by construction — not a gate that might be bypassed, but an operation with
nothing to bypass. `net-open.sh` and `net-close.sh` are deliberately **not** in sudoers.

## Credentials

There are two sets, and only one stays outside.

**The agent's own credential is inside**, and must be. `/home/dev/.claude` is a named
*volume*, not a bind to your host `~/.claude`, so the container gets its own login and your
host credential is never exposed. You log in once, ever — it survives rebuilds.

**Git and cloud credentials stay on the host.** They live in `~/.gitconfig`'s credential
helper, `~/.config/gh/`, `~/.ssh/` — all outside the workspace, so none are mounted. SSH
agent forwarding is explicitly disabled: forwarding shares a *capability*, not a secret, so
anything in the container could ask the agent to sign, for every host that key opens.

The default workflow is therefore **commit inside, push from the host**. `/workspace/.git`
*is* your repository's `.git`, so commits land on host disk instantly; you push from a host
terminal using credentials that never entered the container.

If you must push from inside, use a fine-grained token scoped to that one repository with a
short expiry, passed via `EXTRA_ENV`. It is inert while the network is closed.

## See also

- [configuration.md](configuration.md) — the two files that shape the stack and the boundary
- `CLAUDE.md` — the invariants any change to `core/` or `bin/ccnet` must preserve, each with
  the bug that produced it
