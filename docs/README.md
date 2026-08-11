# docs

Detail that does not belong in the top-level `README.md`.

| | |
|---|---|
| [configuration.md](configuration.md) | `sandbox.conf` and `allowlist.txt` in full — every key, what it renders into, the validation rules, and the edit → re-render → rebuild loop. Start here. |
| [how-it-works.md](how-it-works.md) | The three layers, the privilege model that makes `sudo init-firewall.sh` safe to grant, and where each credential lives. |
| [presets.md](presets.md) | Changing or adding a preset in *this* repository — template anatomy, the placeholder contract, the verification suite. |

`README.md` covers installing and daily use. `CLAUDE.md` states the security invariants that
any change to `core/` or `bin/ccnet` must preserve.

## The one thing people get wrong

`sandbox.conf` is a **compile-time input to `install.sh`**, not a runtime file. Editing it and
running `ccnet rebuild` does nothing: the rebuild rebuilds the *generated* Dockerfile and
compose file, and nothing has regenerated those from your edit yet. Nothing errors — you just
get the old stack back.

```bash
$EDITOR .devcontainer/sandbox.conf             # 1. edit
/path/to/ai-dev-sandbox/install.sh --project . # 2. re-render  <- the step that reads the conf
ccnet rebuild                                  # 3. rebuild the image
```

`allowlist.txt` is the exception: it is copied into the image verbatim from the build context,
so edit + `ccnet rebuild` is enough.
