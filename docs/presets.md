# Changing or adding a preset

A preset is the stack: base image, toolchain, services. It lives in this repository, not in
the installed project. Editing one changes every project installed from it at their next
re-render.

If you only need to change versions, ports, volumes or the allowlist for one project, you do
not want this file — see [configuration.md](configuration.md).

## Anatomy

```
presets/<name>/
├── defaults.conf          # fallback values for every key sandbox.conf may set
├── Dockerfile.tmpl        # rendered to <project>/.devcontainer/Dockerfile
└── docker-compose.yml.tmpl# rendered to <project>/.devcontainer/docker-compose.yml
```

`templates/devcontainer.json.tmpl` is shared by all presets, as are the four files in
`core/`. `core/` is copied **verbatim** and must never be templated — it carries the security
guarantee and has to be byte-identical in every install.

## The placeholder contract

Placeholders are `@@UPPER_SNAKE@@`, substituted by bash parameter expansion in
`install.sh:254-273` — not `sed`, so values never need escaping and multi-line blocks
substitute cleanly. A placeholder you do not use is simply left unsubstituted, so an
unrecognised or misspelled one ships into the generated file as literal text.

| Placeholder | Source | Notes |
|---|---|---|
| `@@MKDIR_LIST@@` | `SANDBOX_VOLUMES` | Space-separated absolute paths. **Required** |
| `@@VOLUME_MOUNTS@@` | `SANDBOX_VOLUMES` | Multi-line, already indented 6 spaces. **Required** |
| `@@VOLUME_DECLS@@` | `SANDBOX_VOLUMES` | Multi-line, indented 2 spaces, under `volumes:`. **Required** |
| `@@USER_UID@@` / `@@USER_GID@@` | invoking user | **Required** — must match the host repo owner or the sandbox user cannot write to the bind mount |
| `@@EXTRA_ENV@@` | `EXTRA_ENV` | Multi-line YAML, indented 6 spaces. **Required** |
| `@@TZ@@`, `@@HTTP_PORT@@`, `@@DOCROOT@@` | `sandbox.conf` | |
| `@@PHP_VERSION@@`, `@@NODE_VERSION@@`, `@@MYSQL_VERSION@@` | `sandbox.conf` | Stack-specific; ignore the ones your stack has no use for |
| `@@DB_NAME@@`, `@@DB_PASSWORD@@` | `sandbox.conf` | |
| `@@PROJECT_NAME@@` | project directory basename | |

Adding a **new** key means editing `install.sh` in three places: the recognised-key list in
`read_conf` (`install.sh:100-101`), a `check` call to validate its characters
(`install.sh:183-190`), and a substitution line in `render`. Skipping the validation is not
an option — see [Every scalar is validated](configuration.md#every-scalar-is-validated).

## Adding a preset

1. Create `presets/<name>/` with the three files above.
2. Support every **Required** placeholder in the table.
3. Copy the airlock block from `presets/php-mysql/Dockerfile.tmpl` **verbatim** — the
   `COPY` / `chown` / `chmod` / sudoers / allowlist / mode-file sequence at the end of the
   file. Do not paraphrase it: the sudoers line grants exactly one command, and the allowlist
   is `COPY`d rather than mounted, for reasons documented inline.
4. Keep the compose `command` pattern: firewall first, exit non-zero on failure, then the
   service.

   ```yaml
   command:
     - /bin/sh
     - -c
     - "/usr/local/bin/init-firewall.sh || exit 1; <service> & exec sleep infinity"
   ```

   The firewall must apply from the compose `command`, not only from `devcontainer.json`'s
   `postStartCommand`. `postStartCommand` runs only under the devcontainer CLI or VS Code;
   a plain `docker compose up` would otherwise leave the container with no firewall while the
   mode file still said `closed`. This regression shipped once and was invisible —
   `ccnet status` reported `closed` while everything was reachable.
5. Background the long-running service and add a healthcheck, so a service crash surfaces as
   `unhealthy` rather than taking the whole sandbox down or going unnoticed.
6. Declare every internal service in `templates/allowlist.txt.example` as `tcp:<name>:<port>`,
   or the app will not reach it while closed.
7. `cap_add` is `NET_ADMIN` and `NET_RAW` **only**. Never `SYS_ADMIN` — it would permit
   remounting filesystems. Never mount the Docker socket.
8. Run the full verification below.
9. Document the provisioned versions in the requirements table in `README.md`.

## Verification

Reading the design does not find these bugs. Every one that mattered was found by running
it. Install into a throwaway project and work through the whole suite:

```bash
SCRATCH=/tmp/sandbox-test
rm -rf $SCRATCH && mkdir -p $SCRATCH/public && cd $SCRATCH && git init -q
cd /path/to/ai-dev-sandbox && ./install.sh --project $SCRATCH --preset <name>
cd $SCRATCH && ccnet up
```

**Start-up** — output must include `Verified: CLOSED (Anthropic only)`.

**Blocked and allowed**, as the sandbox user (`ccnet shell`):

```bash
curl --connect-timeout 5 -s -o /dev/null https://example.com          # must fail
curl --connect-timeout 5 -s -o /dev/null https://github.com           # must fail when closed
curl --connect-timeout 5 -s -o /dev/null https://api.anthropic.com    # must succeed
(echo > /dev/tcp/db/3306)                                             # must succeed
dig +short @8.8.8.8 example.com                                       # must fail
```

**Escalation — the important part.** All must be refused:

```bash
sudo -n /usr/local/bin/net-open.sh          # denied by sudoers
echo open > /etc/claude-net-mode            # permission denied
echo x >> /usr/local/bin/init-firewall.sh   # permission denied
echo x >> /etc/sandbox-allowlist            # permission denied
ls /var/run/docker.sock                     # must not exist
sudo -n -l                                  # exactly one command
sudo -n /usr/local/bin/init-firewall.sh     # ALLOWED, must re-apply CLOSED
```

The last line is the critical assertion. If it reopens the network, the design is broken.

**Round trip**: `ccnet open` → registries reachable; `ccnet close` → blocked again.

**Every start path**: stop the stack and start it with plain `docker compose up -d`, which
skips `postStartCommand` entirely. The firewall must still apply.

**Status honesty**: flush the rules as root (`docker exec -u root <c> iptables -F`) and
confirm `ccnet status` reports `DANGER` and exits non-zero.

**Idempotency**: re-run `install.sh` and confirm `sandbox.conf` and `allowlist.txt` are
preserved while the generated files are refreshed.

**Fail-closed**: point a domain in `allowlist.txt` at something unresolvable, `ccnet open`,
and confirm the firewall forces the mode back to `closed` rather than leaving the mode file
disagreeing with the rules.

## What not to do

The invariants in `CLAUDE.md` are not style preferences; each one exists because its absence
was a real bug. If a preset appears to require breaking one — a second sudoers entry, a
bind-mounted allowlist, `SYS_ADMIN`, a Docker socket — that is a design problem to raise, not
to work around.
