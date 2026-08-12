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

## Telling the agent inside that the airlock is open

`ccnet open` is meant to last seconds, and forgetting `ccnet close` is the most likely way
this sandbox gets used wrong. Two mechanisms surface it, aimed at different readers.

**For a human**: `core/zshrc` draws the mode into the shell prompt, re-reading
`/etc/claude-net-mode` on every prompt (`PROMPT_SUBST`), so an open airlock shows as a red
`[OPEN]`. An agent never sees this — the Bash tool captures a command's stdout, not your
prompt.

**For an agent**: `core/airlock-warn.sh` runs as a `SessionStart` hook and injects a warning
into the agent's context when the airlock is open. Three details make it work:

- It is wired in through `/etc/claude-code/managed-settings.json`, **not** the project and not
  `/home/dev/.claude`. The project must stay untouched — everything ships inside
  `.devcontainer/` — and `/home/dev/.claude` is a named *volume*, seeded from the image only at
  creation, so a file placed there could never be updated by a later rebuild. Managed settings
  are also the highest-precedence scope, and both files are root-owned, so the sandboxed
  process can neither override nor delete the warning.
- `SessionStart` **stdout is not shown to the model**. It has to be JSON carrying
  `hookSpecificOutput.additionalContext`; a bare `echo` is parsed as nothing and discarded in
  silence. That is why this is a script rather than a one-liner in the settings file.
- It also probes `example.com`, which is never allowlisted in either mode. Reachable means no
  firewall applied at all — the same condition `ccnet status` reports as `DANGER`, and worse
  than an open airlock, because the mode file then claims a protection that does not exist.
  The probe is cheap in the normal case: the firewall `REJECT`s rather than drops, so it
  returns immediately instead of waiting out the timeout.

It says nothing when the airlock is closed and enforced. A reassurance every session is noise,
and noise is what gets warnings ignored.

**When nobody is reading**: a warning is useless in an unattended run, so `core/net-guard.sh`
runs as a `PreToolUse` hook on `WebFetch|WebSearch` and *refuses* rather than warns. It denies
whenever the session is unattended, which for `WebFetch` means only while the airlock is open:

| Tool | Airlock | Session | Result |
|---|---|---|---|
| `WebFetch` | closed | any | allowed — the firewall already refuses the connection |
| `WebFetch` | open | `default`, `plan`, `acceptEdits` | allowed — `default` already prompts for it; a second gate is friction with no gain |
| `WebFetch` | open | anything else | **denied** |
| `WebSearch` | **either** | `default`, `plan`, `acceptEdits` | allowed |
| `WebSearch` | **either** | anything else | **denied** |

`WebSearch` does not get the closed-mode pass, because the firewall never sees it. It runs
server-side and its results arrive over the `api.anthropic.com` channel that `init-firewall.sh`
permits as `required` in **both** modes. Measured, not assumed: with the airlock closed,
`WebFetch` of `github.com` returned `ECONNREFUSED` while `WebSearch` returned snippets from four
external sites. Closed mode was therefore the *more* permissive state for search — the inverse
of the intent, since search results are attacker-influenceable text and that is injection
surface whatever the airlock is doing.

"Anything else" is literal: the guard **allowlists** the attended modes rather than denylisting
the unattended ones. An unrecognised or undeterminable `permission_mode` denies, so a mode added
or renamed by a future release fails closed instead of silently passing. The earlier denylist
form — `bypassPermissions|dontAsk|auto` — would have opened this up with no sign.

`deny` rather than `ask`, deliberately: deny is documented to block, whereas whether `ask` is
auto-approved under `--dangerously-skip-permissions` is not something this should rest on.

Both hooks are advisory, not load-bearing. Removing them weakens no invariant.

**And `net-guard.sh` is a tripwire, not a boundary.** It covers the agent's declared network
tools and nothing else. Outbound traffic from `Bash` — `composer install`, `git fetch`, a test
suite calling an API — is not matched, and must not be: those are precisely what an open
airlock is *for*, and matching command strings for `curl` is trivially evaded. The iptables
airlock remains the control; this only closes the case where an agent reaches out through its
own tools while no one is watching.

The `WebSearch` case generalises, and is worth carrying into any change here: **iptables cannot
see anything whose transport is the `api.anthropic.com` channel**, because that connection is
`required` in both modes — Claude does not run without it. Server-side tools and remote MCP
servers reached through the API are outside the airlock in *every* state, and a hook is the only
control available for them. The matcher is a list of names, so anything new is permitted until
it is added.

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
