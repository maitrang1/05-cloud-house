# Config Reference

Plain facts — where things go, what gets skipped. For steps, see `10-HOW-TO.md`.

---

## The Program
| Item | Value |
|---|---|
| File | `zig-out/bin/cf-cron-setup` (`cf-cron-setup.exe` on Windows) |
| Run | `cf-cron-setup <run\|sync\|status\|check\|secret\|revoke\|vault\|help> [--go] [--conf <file>]` |
| Settings file | `00-config.json` in the folder you run it from, or the file after `--conf` |
| Built with | Zig 0.16.0, no outside libraries |

## Commands
| Command | What it does |
|---|---|
| `run` | Preview only. With `--go` it runs for real and picks up where it stopped. |
| `sync --go` | After you change `cron`, `trig` or the tick secret: uploads again if needed, fixes the cron. |
| `status` | Shows the account, Worker address, cron and each step's mark. |
| `check` | Asks the Worker address and the live cron right now. |
| `secret <vault-key>` | Stores one hidden value in the vault (for example `trigger.tick_secret`). |
| `revoke --go` | Turns the cron off (the Worker stays) and forgets the token. |
| `vault` | Shows the vault path and how many secrets it holds. |

## Settings (`00-config.json`)
Every key must be present. A typo or an unknown key stops the app and names the line.

| Setting | What it does | Default | Allowed |
|---|---|---|---|
| `vers` | Settings format version | `1` | `1` |
| `data.root` | Folder for the vault, state, log and wiring file; `{home}` is your home folder | `{home}/.05-cloud-house-secre` | any path |
| `data.vaul` / `stat` / `audi` | Vault, progress and log file names | `cf-cron-vault.json` / `cf-cron-state.json` / `cf-cron-audit.log` | file names |
| `data.wire` | Wiring file the Schedule layer reads | `schedule-c.json` | file name |
| `vaul.envz` | Environment variable that holds the vault passphrase | `CLOUD_HOUSE_VAULT_PASS` | name |
| `vaul.time` / `memo` / `para` | Vault lock strength (time, memory in KiB, threads) | `3` / `65536` / `1` | positive numbers |
| `vaul.keyz` | Vault name of the Cloudflare API token | `cloudflare.apitoken` | name |
| `cfla.apiz` | Cloudflare API address | `https://api.cloudflare.com/client/v4` | URL |
| `cfla.sign` / `keyp` | Pages opened for sign-up / for the API token | Cloudflare pages | URL |
| `cfla.minl` | Shortest token accepted | `30` | 8 or more |
| `cfla.acco` | Account id to use; empty means the first one | empty | text |
| `cfla.subd` | Your `workers.dev` name; empty means a stable one is made | empty | lowercase letters, digits, `-` |
| `cfla.scri` | Worker name | `cloud-house-tick` | text |
| `cfla.rout` | Worker address template; must hold `{scri}` | `https://{scri}.{subd}.workers.dev` | URL |
| `cfla.comp` | Worker runtime date | `2025-01-01` | date |
| `trig.url` | Your Trigger address. **You must set this.** | empty | URL, no path |
| `trig.path` / `meth` | Path and method the Worker calls | `/tick` / `POST` | path starts with `/` |
| `trig.head` | Header that carries the tick secret | `x-tick-secret` | header name |
| `trig.secr` | Vault name of the tick secret (optional) | `trigger.tick_secret` | name |
| `cron.peri` | Minutes between ticks | `5` | 1,2,3,4,5,6,10,12,15,20,30 |
| `rout.wait` / `poll` | Seconds to wait for the Worker address / between checks | `120` / `5` | numbers |
| `wire.slot` / `laye` | Slot letter and layer written to the wiring file | `C` / `schedule` | text |
| `guid.open` / `clip` | Open pages / fill the clipboard for you | `true` / `true` | `true`/`false` |
| `guid.poll` / `wait` | Seconds between checks / longest wait for you | `5` / `900` | numbers |
| `http.trys` / `back` / `maxw` | Retries, first back-off, longest back-off (seconds) | `4` / `2` / `60` | numbers |
| `http.agen` / `maxb` | Name sent to Cloudflare / largest answer in bytes | `cloud-house-cf-cron/1` / `4194304` | text / number |
| `limi.reqs` / `warn` / `trig` | Free requests per day / warning percent / free cron triggers | `100000` / `80` / `5` | numbers |

## Input
| Part | Meaning |
|---|---|
| Vault passphrase | Env var named in `vaul.envz`, or typed hidden when missing |
| API token | Pasted once, hidden, with Workers Scripts Edit + Account Settings Read |
| Tick secret | Optional, stored with `secret`, sent to your Trigger as a header |

## Output
| Item | Value |
|---|---|
| Wiring file | `{data.root}/schedule-c.json`: slot, layer, Worker name and address, cron, ticks per day |
| Progress file | `{data.root}/cf-cron-state.json`: step marks and ids, never a secret |
| Log | `{data.root}/cf-cron-audit.log`: one line per call, secrets masked |
| Exit codes | `0` ok · `1` failed · `2` bad usage or config · `4` stopped at a hand step |

Good to know: Cloudflare keeps a cron change off the network for up to 15 minutes. Free Workers get 5 cron triggers per account and 100,000 requests a day; one tick every 5 minutes is 288 a day. Cloudflare does not retry a missed tick: your Trigger side owns retries.

## Files In This Tool
```
00-config.json   — all settings
10-steps.json    — the step list
df-worker.js     — the Worker that is uploaded
cf-cron-setup    — the program
```
