# ai-dev-sandbox

A hardened devcontainer for running AI coding agents unattended, with a **network airlock**
you control from the host.

The container's network is closed by default — reachable only to the Claude API, so the
agent still runs — and you open it deliberately, for the seconds a dependency install or a
push takes.

```
[closed] /workspace %          # the agent works, the internet does not answer
```

## What it gives you

- The agent works freely inside the project directory
- It cannot reach the internet unless you open the network
- **It cannot open the network itself** — the control lives on the host
- It cannot reach your SSH keys, cloud credentials, or anything outside the project
- Commits happen inside; pushes happen from the host, after you have read the diff

## Requirements

| | |
|---|---|
| **Docker** | On a host you control, running the container locally. Docker Engine, Docker Desktop, OrbStack, Rancher Desktop or colima. |
| **A host shell** | Outside the container, to drive the airlock. |
| **devcontainer CLI** | `npm i -g @devcontainers/cli` — needed by `ccnet up`. |
| **An editor** | Optional. VS Code (Dev Containers extension), JetBrains, Cursor, or none at all. |

The `php-mysql` preset provisions **PHP 8.4 (Apache) · Node 20 · MySQL 8.4 · Composer 2**,
all configurable in `sandbox.conf`.

Cloud and remote dev environments such as GitHub Codespaces are **not suitable** — your
shell lives inside the container's host, so the guarantee that the agent cannot reopen the
network no longer holds.

## Install

```bash
git clone https://github.com/mikenuguid/ai-dev-sandbox.git
cd ai-dev-sandbox
./install.sh --project /path/to/your/project
```

Add `--interactive` to be prompted for versions and ports on a first run, or `--force` to
overwrite a `.devcontainer/` this installer did not create.

It writes into your project:

```
.devcontainer/
├── sandbox.conf         # you edit this
├── allowlist.txt        # you edit this
├── Dockerfile           # generated
├── docker-compose.yml   # generated
├── devcontainer.json    # generated
├── init-firewall.sh     # core — do not edit
├── net-open.sh          # core — do not edit
├── net-close.sh         # core — do not edit
└── zshrc                # core
```

and installs `ccnet` to `~/.local/bin`.

Re-running is safe: generated files are refreshed, `sandbox.conf` and `allowlist.txt` are
never clobbered.

## First run

```bash
cd /path/to/your/project

ccnet up                 # build and start (first build takes a few minutes)
ccnet open               # allow the registries
ccnet shell              # inside: composer install, yarn install, claude (log in once)
ccnet close              # back to Anthropic-only
ccnet status             # closed  myproject_devcontainer-app-1  (enforced)
```

Watch the start-up output for `Verified: CLOSED`. If the firewall fails to apply, container
start fails — deliberately. Do not work around it.

## Daily use

| Command | What it does |
|---|---|
| `ccnet up` | Start the sandbox |
| `ccnet rebuild` | Recreate after editing anything in `.devcontainer/` |
| `ccnet shell` | Shell inside, as the sandbox user |
| `ccnet status` | Airlock mode, **and** whether it is actually enforced |
| `ccnet open` | Open the allowlist |
| `ccnet close` | Close to Anthropic only |
| `ccnet down` | Stop the stack (volumes kept) |

All take an optional folder argument: `ccnet status /path/to/project`.

The loop is **sequencing**: open the network, install everything up front, close it, then
let the agent work — which is almost entirely local.

1. `ccnet open` → clone, install dependencies, fetch docs
2. `ccnet close` → let the agent work unattended
3. Review `git log` / `git diff` **on the host**
4. `git push` **from the host**

A habit worth building: **`ccnet status` before starting an unattended run.** One command,
and it is the difference between a sandbox and the appearance of one.

### What works in each state

| | **open** | **closed** |
|---|---|---|
| Public clone / fetch | yes | no |
| Package install | yes | no |
| WebFetch / WebSearch | yes | no |
| Private fetch, push | no — no credentials | no |
| The agent itself | yes | yes |
| Your database | yes | yes |

Always works in both: all local file operations; all local git (`commit`, `branch`,
`rebase`, `merge`, `stash`, `log`, `diff`, `reset`); builds, tests and linters from
installed dependencies; dev servers on localhost.

## Configuration

Two files, and the split is about **cost of change**.

### `.devcontainer/sandbox.conf`

Stack shape. Compiled into the image, so changes need `ccnet rebuild`.

```sh
PRESET=php-mysql

PHP_VERSION=8.4
NODE_VERSION=20
MYSQL_VERSION=8.4
TZ=UTC

HTTP_PORT=8080          # host port for the site
DOCROOT=public          # web root, relative to the project

DB_NAME=db
DB_PASSWORD=root

SANDBOX_VOLUMES="
vendor
node_modules
public/assets
"
```

| Key | Default | Notes |
|---|---|---|
| `PRESET` | `php-mysql` | Which preset to render from |
| `PHP_VERSION` | `8.4` | Any tag of the `php:<v>-apache` image |
| `NODE_VERSION` | `20` | NodeSource major version |
| `MYSQL_VERSION` | `8.4` | Any tag of the `mysql` image |
| `TZ` | `UTC` | Container timezone |
| `HTTP_PORT` | `8080` | Host port. Avoid 80/443 if another local stack uses them |
| `DOCROOT` | `public` | Web root, relative to the project |
| `DB_NAME` | `db` | Database created on first start |
| `DB_PASSWORD` | `root` | Dev only — never exposed on a host port |
| `SANDBOX_VOLUMES` | `vendor`, `node_modules` | Generated dirs kept off the bind mount |
| `EXTRA_ENV` | — | Extra environment, added verbatim to the app service |

**`SANDBOX_VOLUMES` is the one to get right.** List anything *generated* rather than
authored: dependency trees, build output, framework caches, uploaded assets. Three reasons
they belong in volumes rather than on the bind mount:

1. Host files there are often owned by another user (`www-data`, `root`). The sandbox user
   can write via group but cannot `chmod`, which needs ownership — and frameworks do chmod.
2. Host and container toolchain versions differ, so sharing built dependencies mixes
   incompatible native builds.
3. It stops this stack and any other local stack (DDEV, Lando) corrupting each other's caches.

This single list generates **both** the Dockerfile `mkdir` list and the compose volume list.
That is deliberate: when those two disagree, Docker creates the volume owned by `root` and
the failure surfaces much later as an unwritable directory needing `docker volume rm`.

`EXTRA_ENV` is where framework config goes, and where you opt out of packages whose
postinstall downloads binaries from hosts you have not allowlisted:

```sh
EXTRA_ENV="
APP_ENV: dev
CYPRESS_INSTALL_BINARY: \"0\"
PUPPETEER_SKIP_DOWNLOAD: \"1\"
"
```

### `.devcontainer/allowlist.txt`

What the network may reach. Also baked into the image, so also needs `ccnet rebuild`.

```
# Domains — reachable only when the airlock is OPEN
github.com
api.github.com
codeload.github.com
objects.githubusercontent.com
packagist.org
repo.packagist.org
registry.npmjs.org
registry.yarnpkg.com

# Internal services — reachable in BOTH modes
tcp:db:3306
```

| Entry | Meaning |
|---|---|
| `example.com` | A domain. Allowed only while **open**. |
| `tcp:host:port` | An internal service. Allowed in **both** modes, because an app must still reach its database while closed. Must resolve to a private address; a public one is refused and logged. |

`api.anthropic.com` is always permitted and must not be listed — without it the agent cannot
run at all.

**Why it is baked in rather than mounted.** An earlier design mounted this file read-only at
`/etc/sandbox-allowlist`. That gives no protection: the same file is also visible read-write
under `/workspace`, and `:ro` only blocks writes *through that mount point*, not through
another path to the same inode. The sandboxed process could edit it and run
`sudo init-firewall.sh` to apply its own additions. Baking it in means changing the allowlist
requires a rebuild, which only the host can trigger.

The same reasoning applies to `sandbox.conf`: the agent can edit it, but nothing happens
until **you** rebuild. Treat `.devcontainer/` changes as you would any other code change —
review them.

## How it works

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

### The privilege model

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

### Credentials

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

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `ccnet: no running devcontainer` | Not running, wrong folder, or the container was started with plain `docker compose up`, which sets no `devcontainer.local_folder` label. `ccnet up` will *adopt* such a container rather than relabel it — use **`ccnet rebuild`** to recreate it properly. |
| Edited `.devcontainer/*` but nothing changed | `ccnet up` reuses a running container. Use `ccnet rebuild`. |
| Container will not start, firewall test fails | A domain failed to resolve, or `api.anthropic.com` is unreachable. Non-zero exit is by design. |
| A command hangs instead of erroring | Firewall, not auth. The host is not in the ipset — add it to `allowlist.txt` and `ccnet rebuild`. |
| Package install fails with a connection error | Airlock closed, or the registry is missing from `allowlist.txt`. Check `ccnet status`. |
| Install fails **only for one package** | Its postinstall downloads a binary from a non-allowlisted host (Cypress, Puppeteer, Playwright). Skip it via `EXTRA_ENV`, or allowlist the host. |
| Downloads fail minutes after `ccnet open` | CDN rotation. The firewall resolves three times and allows each `/24`, but a large CDN can still rotate outside that. Re-run `ccnet open`. |
| `rm -rf node_modules` → `Device or resource busy` | It is a mount point. Use `rm -rf node_modules/*`, or `ccnet down` and `docker volume rm`. |
| App cannot reach its database | Missing `tcp:db:3306` in `allowlist.txt`, or it resolves to a public address and was refused. |
| Asked to log in to the agent again | The `claude-config` volume was removed, or the project path changed. |
| Network still reachable after `ccnet close` | A live connection surviving `ESTABLISHED,RELATED`. Confirm `conntrack` is installed in the image. |
| `docker compose down` did nothing | Wrong project name. Use `ccnet down`, which reads it off the running container. |

## Limitations

Stated plainly, because a sandbox you trust too much is worse than one you understand.

- **This is not a hard security boundary.** Docker does not protect against a genuine
  container escape.
- **The threat it handles well is the agent going wrong** — a bad command, a runaway loop, a
  misread instruction. It handles a *deliberate attacker steering the agent via prompt
  injection* less well, though a closed-by-default network removes most of the channels such
  a payload would need.
- **The workspace bind is your real repository.** A `git reset --hard`, a history rewrite or
  a mass delete lands on host disk immediately. The container protects everything *except*
  the repository — which is where damage is most likely.
- **Open windows are the exposure.** Do not open the network while the agent is mid-task on
  content you did not write.
- **The `/24` expansion is wider than the domains you listed.** A CDN `/24` may host
  unrelated tenants. Tight domain filtering needs a filtering proxy, not iptables.
- **This does not make unattended runs safe on untrusted code**, or in a repository holding
  production credentials.

## Running alongside another local stack

DDEV, Lando, a hand-rolled compose — these do not conflict directly, but both bind-mount the
**same working tree**.

**Do not run both at once.** Concurrent writes collide on dependency trees, framework caches
and `.git/index.lock`. Putting generated directories in `SANDBOX_VOLUMES` removes most of the
overlap; source and `.git` are still shared. Stop the other stack first.

**Never mount the host's Docker socket** into the container so it can drive the other stack.
That hands it full control of the host Docker daemon — it could start a privileged container
and mount the host filesystem. It does not weaken the boundary, it removes it.

## Adding a preset

See `CLAUDE.md`.
