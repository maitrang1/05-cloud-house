# Config Reference

Plain facts — where things go, what gets skipped. For steps, see `10-HOW-TO.md`.

---

## The Program
| Item | Value |
|---|---|
| File | `zig-out/bin/render-setup` (`render-setup.exe` on Windows) |
| Run | `render-setup <run\|status\|cold\|revoke\|vault\|help> [--go] [--conf <file>]` |
| Settings file | `00-config.json` in the folder you run it from, or the file after `--conf` |
| Built with | Zig 0.16.0, no outside libraries |

## Commands
| Command | What it does |
|---|---|
| `run` | Preview only. With `--go` it runs for real and picks up where it stopped. |
| `status` | Shows the service id, address, last wake time and each step's mark. |
| `cold` | Times one cold start right now. |
| `revoke --go` | Pauses the service this app made and forgets the key. You can resume the service in the dashboard. |
| `vault` | Shows the vault path and how many secrets it holds. |

## Settings (`00-config.json`)
Every key must be present. A typo or an unknown key stops the app and names the line.

| Setting | What it does | Default | Allowed |
|---|---|---|---|
| `vers` | Settings format version | `1` | `1` |
| `data.root` | Folder for the vault, state, log and wiring file; `{home}` is your home folder | `{home}/.05-cloud-house-secre` | any path |
| `data.vaul` | Vault file name | `render-vault.json` | file name |
| `data.stat` | Progress file name | `render-state.json` | file name |
| `data.audi` | Log file name | `render-audit.log` | file name |
| `data.wire` | Wiring file the Schedule layer reads | `trigger-c.json` | file name |
| `vaul.envz` | Name of the environment variable that holds the vault passphrase | `CLOUD_HOUSE_VAULT_PASS` | name |
| `vaul.time` / `memo` / `para` | Vault lock strength (time, memory in KiB, threads) | `3` / `65536` / `1` | positive numbers |
| `vaul.keyz` | Vault name of the Render API key | `render.apikey` | name |
| `rend.apiz` | Render API address | `https://api.render.com/v1` | URL |
| `rend.sign` | Page opened for sign-up | `https://dashboard.render.com/register` | URL |
| `rend.keyp` | Page opened for the API key | `https://dashboard.render.com/u/settings#api-keys` | URL |
| `rend.keyf` | What a real key starts with | `rnd_` | text |
| `rend.owne` | Workspace name to use; empty means the first one | empty | text |
| `rend.name` | Service name (unique in your workspace) | `cloud-house-trigger` | text |
| `rend.kind` | Service kind | `web_service` | `web_service` |
| `rend.imag` | Your public image path. **You must set this.** | empty | image path |
| `rend.plan` | Plan. Anything but `free` needs the guard below. | `free` | `free` or a paid plan name |
| `rend.regi` | Data center | `oregon` | `oregon`, `ohio`, `virginia`, `frankfurt`, `singapore` |
| `rend.heal` | Health check path | `/healthz` | starts with `/` |
| `rend.inst` | Number of instances | `1` | 1 or more |
| `envs` | Env vars to send: `name`, `vaul` (vault key holding the value), `need` (stop if empty) | one optional `HEALTHCHECKS_URL` | list |
| `guar.paid` | Allow a paid plan | `false` | `true`/`false` |
| `guar.capz` | Monthly spending cap in USD; must be above 0 for a paid plan | `0` | number |
| `wire.slot` / `wire.laye` | Slot letter and layer written to the wiring file | `C` / `trigger` | text |
| `cold.wait` | Seconds to wait for the service to answer | `600` | number |
| `cold.poll` | Seconds between checks | `5` | 1 or more |
| `cold.wind` | Your 202 window in seconds; slower wakes are flagged | `60` | number |
| `guid.open` / `clip` | Open pages / fill the clipboard for you | `true` / `true` | `true`/`false` |
| `guid.poll` / `wait` | Seconds between checks / longest wait for you | `5` / `900` | numbers |
| `http.trys` / `back` / `maxw` | Retries, first back-off, longest back-off (seconds) | `4` / `2` / `60` | numbers |
| `http.agen` / `maxb` | Name sent to Render / largest answer in bytes | `cloud-house-render/1` / `4194304` | text / number |
| `limi.hour` / `day` / `warn` | Free hours per month / days counted / warning percent | `750` / `31` / `80` | numbers |

## Input
| Part | Meaning |
|---|---|
| Vault passphrase | Env var named in `vaul.envz`, or typed hidden when missing (8+ characters) |
| API key | Pasted once, hidden, starts with `rnd_` |
| Env values | Stored in the vault under the key named in each `envs` row |

## Output
| Item | Value |
|---|---|
| Wiring file | `{data.root}/trigger-c.json`: slot, layer, address, health path, service id, plan |
| Progress file | `{data.root}/render-state.json`: step marks and ids, never a secret |
| Log | `{data.root}/render-audit.log`: one line per call, secrets masked |
| Exit codes | `0` ok · `1` failed · `2` bad usage or config · `4` stopped at a hand step |

Good to know: the env list replaces everything on the service. A variable you remove from `envs` disappears from Render on the next change.

## Files In This Tool
```
00-config.json   — all settings
10-steps.json    — the step list
render-setup     — the program
```
