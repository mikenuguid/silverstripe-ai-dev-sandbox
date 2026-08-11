# Configuration

Two files in `<project>/.devcontainer/` describe your sandbox, and the split between them is
about **cost of change**.

| File | Controls | To change it |
|---|---|---|
| `sandbox.conf` | The stack shape — versions, ports, docroot, volumes, environment | Edit → re-run `install.sh` → `ccnet rebuild` |
| `allowlist.txt` | The network boundary — what the firewall will permit | Edit → `ccnet rebuild` |

Both are **inputs to `install.sh`**; neither is read at container runtime. Everything else in
`.devcontainer/` is either generated (`Dockerfile`, `docker-compose.yml`, `devcontainer.json`)
or copied verbatim from `core/` (`init-firewall.sh`, `net-open.sh`, `net-close.sh`, `zshrc`).
Do not hand-edit those; the next `install.sh` run overwrites them.

## The change loop

The two files differ, and this is the thing to get right.

**`sandbox.conf` — three steps.** Step 2 is the one that gets skipped.

```bash
# 1. edit the config
$EDITOR /path/to/project/.devcontainer/sandbox.conf

# 2. re-render the generated files from it — THIS is what reads the conf
cd /path/to/ai-dev-sandbox
./install.sh --project /path/to/project

# 3. rebuild the image and recreate the container
cd /path/to/project && ccnet rebuild
```

Here `ccnet rebuild` alone is **necessary but not sufficient**. It recreates the container
from the generated `Dockerfile` and `docker-compose.yml` — files that still hold your
previous values until `install.sh` re-renders them. Nothing errors; you simply get the old
stack back and conclude the setting does not work.

**`allowlist.txt` — two steps.** Edit, then `ccnet rebuild`. No installer re-run: this file
is not generated and not templated. It already sits in the build context
(`.devcontainer/`, the compose `context: .`) and the Dockerfile `COPY allowlist.txt
/etc/sandbox-allowlist` layer invalidates on its checksum, so a rebuild picks the edit up
directly.

Verify after either: the start-up output must contain `Verified: CLOSED (Anthropic only)`,
and `ccnet status` must report `closed ... (enforced)`.

Re-running the installer is safe. It preserves `sandbox.conf` and `allowlist.txt` untouched
and refreshes only the generated files and the `core/` scripts. It also reads `PRESET` back
out of your existing conf (`install.sh:45-52`), so `--preset` is not needed on a re-run —
and passing the wrong one would silently replace a working stack.

When in doubt, run all three steps. The installer is idempotent, so the extra step costs
nothing.

## `.devcontainer/sandbox.conf` — the stack shape

```sh
PRESET=php-mysql

PHP_VERSION=8.4
PHP_MEMORY_LIMIT=128M
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

Parsed key-by-key (`install.sh:89-121`), never sourced. Unrecognised keys are warned about
and ignored. Any key you omit falls back to `presets/<name>/defaults.conf`.

| Key | Default | Where it lands | Notes |
|---|---|---|---|
| `PRESET` | `php-mysql` | picks `presets/<name>/` | Which template set renders |
| `PHP_VERSION` | `8.4` | `Dockerfile.tmpl:6` → `FROM php:<v>-apache` | Any tag of the `php:<v>-apache` image |
| `PHP_MEMORY_LIMIT` | `128M` | `Dockerfile.tmpl:38` → `conf.d/zz-sandbox.ini` | PHP's `memory_limit`, CLI and Apache alike. A size with a suffix, or `-1` |
| `NODE_VERSION` | `20` | `Dockerfile.tmpl:45` → NodeSource setup script | Node major version |
| `MYSQL_VERSION` | `8.4` | `docker-compose.yml.tmpl:82` → `image: mysql:<v>` | Any tag of the `mysql` image |
| `TZ` | `UTC` | Dockerfile `ARG`/`ENV` + compose build arg | Container timezone |
| `HTTP_PORT` | `8080` | `docker-compose.yml.tmpl:57` → `"<port>:80"` | Host port. Avoid 80/443 if another local stack uses them |
| `DOCROOT` | `public` | `Dockerfile.tmpl:40` → `APACHE_DOCUMENT_ROOT` | Apache web root, relative to the project |
| `DB_NAME` | `db` | compose `db` env | Database created on first start |
| `DB_PASSWORD` | `root` | compose `db` env + healthcheck | Dev only — never exposed on a host port |
| `SANDBOX_VOLUMES` | `vendor`, `node_modules` | **both** `Dockerfile.tmpl:65` mkdir list and the compose volume mounts + declarations | Generated dirs kept off the bind mount |
| `EXTRA_ENV` | — | `docker-compose.yml.tmpl:52`, verbatim YAML | Extra environment on the app service |

Line references are to the templates in this repo; the generated files mirror them, though
numbering shifts past a multi-line placeholder.

### `SANDBOX_VOLUMES` is the one to get right

List anything *generated* rather than authored: dependency trees, build output, framework
caches, uploaded assets. Three reasons they belong in volumes rather than on the bind mount:

1. Host files there are often owned by another user (`www-data`, `root`). The sandbox user
   can write via group but cannot `chmod`, which needs ownership — and frameworks do chmod.
2. Host and container toolchain versions differ, so sharing built dependencies mixes
   incompatible native builds.
3. It stops this stack and any other local stack (DDEV, Lando) corrupting each other's caches.

This single list drives **both** the Dockerfile `mkdir` list and the compose volume list
(`install.sh:206-230`), and that is deliberate. Never hand-edit one side of the generated
output. When the two disagree, Docker seeds the volume from a path that does not exist in the
image, so it lands empty and owned by `root` — and the failure surfaces much later as an
unwritable directory needing `docker volume rm`.

**Changing the list may need a volume wipe.** Adding a path is fine. Renaming or removing one
leaves the old named volume behind with stale contents; a rebuild does not clear it. If a
volume was ever seeded root-owned, remove it explicitly:

```bash
docker volume ls | grep <project>          # names derive from the path: public/assets -> public-assets
docker volume rm <project>_devcontainer_<name>
```

### `EXTRA_ENV` is YAML, not shell

This is where framework config goes, and where you opt out of packages whose postinstall
downloads binaries from hosts you have not allowlisted — those would otherwise make
`install` exit non-zero.

```sh
EXTRA_ENV="
APP_ENV: dev
CYPRESS_INSTALL_BINARY: '0'
PUPPETEER_SKIP_DOWNLOAD: '1'
"
```

Write `KEY: 'value'`, and do **not** backslash-escape the quotes. The file is parsed rather
than sourced, so a `\"` survives literally into `docker-compose.yml` and breaks the YAML
parse.

### Every scalar is validated

Values are character-checked (`install.sh:179-200`) before interpolation. `PHP_VERSION`
allows only `[A-Za-z0-9._-]`; `PHP_MEMORY_LIMIT` only `[0-9KMGkmg-]`; `DOCROOT` must be
relative and free of `..`; `HTTP_PORT` must be 1–65535. Anything else aborts the install.

This is not fussiness. These values are interpolated into a Dockerfile that the host then
*builds*, and `sandbox.conf` lives inside the project the sandboxed agent can write to. An
unvalidated value is a route to arbitrary build content on the host.

## `.devcontainer/allowlist.txt` — the network boundary

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

Copied to `/etc/sandbox-allowlist` in the image (`Dockerfile.tmpl:107`), root-owned, `0644`.
Parsed at firewall-apply time (`core/init-firewall.sh:54-70`). Two entry forms:

| Entry | Meaning |
|---|---|
| `example.com` | A domain. Resolved when the firewall applies and added to the `allowed-domains` ipset. Reachable **only while the airlock is OPEN**. |
| `tcp:host:port` | An internal service. Reachable in **both** modes, because an app must still reach its database while closed. Validated to resolve to a private address; a public one is refused and logged (`init-firewall.sh:190-214`). |

`api.anthropic.com` is always permitted and **must not be listed** — without it the agent
cannot run at all.

Each resolved IP is expanded to its containing `/24` (`init-firewall.sh:161`). That is wider
than the domain you asked for, and it is a deliberate trade-off: exact-IP allowlisting does
not survive CDN rotation, and package installs then fail minutes after opening. Tight domain
filtering needs a filtering proxy, not iptables.

### Why it is baked in rather than mounted

An earlier design mounted this file read-only at `/etc/sandbox-allowlist`. That gives no
protection: the same file is also visible read-write under `/workspace`, and `:ro` only
blocks writes *through that mount point*, not through another path to the same inode. The
sandboxed process could edit it and run `sudo init-firewall.sh` to apply its own additions.

Baking it in means changing the allowlist requires a rebuild, which only the host can
trigger (invariant 7 in `CLAUDE.md`). The rebuild cost is the security feature.

The same reasoning applies to `sandbox.conf`: the agent can edit it, but nothing happens
until **you** re-render and rebuild. Treat `.devcontainer/` changes as you would any other
code change — review them.

### The escape hatch for a one-off

`ccnet open` / `ccnet close` toggle the airlock against the already-baked list, with no
rebuild. You only need the rebuild to change *what is on* the list.

## Common changes

| Goal | Do this |
|---|---|
| A registry or docs host is unreachable when open | Add the domain to `allowlist.txt`, rebuild |
| One package's postinstall fails while others work | It downloads a binary from a non-allowlisted host. Opt out via `EXTRA_ENV`, or allowlist the host |
| Port collision on start | Change `HTTP_PORT`; `install.sh` warns if the new one is also taken |
| Framework writes into a bind-mounted cache and fails on chmod | Add that path to `SANDBOX_VOLUMES` |
| Add a second service the app must reach while closed | Add the service to the compose template in the preset, and `tcp:<name>:<port>` to `allowlist.txt` |
| Outgrown the preset entirely | Edit `.devcontainer/Dockerfile` directly and stop re-running `install.sh` for that project — or add a preset (see [presets.md](presets.md)) |

## See also

- [how-it-works.md](how-it-works.md) — the privilege model these files feed, and why the
  control lives on the host
- [presets.md](presets.md) — changing what the templates themselves render
