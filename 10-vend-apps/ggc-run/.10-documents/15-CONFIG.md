# Config Reference

Plain facts: where things go, what each setting does. For steps, see `10-HOW-TO.md`.

---

## The Program
| Item | Value |
|---|---|
| File | `/home/mai_trang/05-cloud-house/10-vend-apps/ggc-run/zig-out/bin/ggc-run` |
| Run | `ggc-run <run\|plan\|status\|usage\|revoke\|help> [--go] [--conf PATH]` |
| Settings file | `00-config.json` in the folder you run from (or `--conf PATH`) |
| Memory folder | `{home}/.05-cloud-house-secre/` |
| Built with | Zig 0.16.0, nothing else |
| Exit codes | 0 ok · 1 failed · 2 wrong use or bad settings · 3 quota at the warn level · 4 waiting for you |

A misspelled or unknown setting stops the tool and names the line and column.

---

## Settings (`00-config.json`)
| Setting | What it does | Default | Allowed |
|---|---|---|---|
| `vers` | Settings format number | `1` | `1` |
| `data.root` | Memory folder; `{home}` is your home folder | `{home}/.05-cloud-house-secre` | any path |
| `data.stat` | State file name | `ggc-run-state.json` | file name |
| `data.audi` | Log file name | `ggc-run-audit.log` | file name |
| `data.hand` | Handoff file name (tick address for the timer) | `ggc-run-handoff.json` | file name |
| `data.step` | Optional steps file next to the settings; the built-in copy is used if absent | `df-steps.json` | file name |
| `goog.regi` | Cloud Run region | `us-central1` | must be in `goog.free` (other regions bill from the first second) |
| `goog.free` | Free-tier regions (Iowa, S. Carolina, Oregon) | `us-central1`, `us-east1`, `us-west1` | list of region ids |
| `goog.proj_base` | Start of a new project id | `cloud-house` | 6-30 chars: lowercase, digits, hyphen |
| `goog.proj_iden` | Fixed project id (empty = base + random 6) | empty | legal project id or empty |
| `goog.proj_name` | Project display name | `Cloud House` | text |
| `goog.serv` | Service name | `cloud-job` | text |
| `goog.sacc` | Runtime account name | `cloud-job-run` | 6-30 chars |
| `goog.arty` | Pull-through repo name | `ghcr-remote` | text |
| `apis.*` | Base address of each Google API (`crmz bill budg usag iamz arti runz moni`) | real Google addresses | `https://`; `http://127.0.0.1` only for the pretend Google |
| `enab` | APIs to switch on | 8 APIs | list of API names |
| `auth.mode` | Where the access token comes from | `gcloud` | `gcloud`, `env` |
| `auth.toke_envz` | Env variable holding the token (mode `env`) | `GGC_RUN_TOKEN` | name |
| `auth.quot_head` | Send the quota-project header after the APIs are on | `true` | `true`/`false` |
| `auth.life_secs` | How long a `gcloud` token is reused | `2700` | seconds |
| `tool.gclo` | The `gcloud` program | `gcloud` | name or full path |
| `tool.time` | Time limit for helper programs | `600` | seconds |
| `gclo.acct/logi/toke/revo` | Arguments for `gcloud` (`{acct}` = account) | standard | lists of text |
| `budg.name` | Budget name | `cloud-house-ggc-run` | text |
| `budg.amou` | Budget amount (whole units, your billing currency); alert at each `budg.step` | `1` | 1 or more |
| `budg.step` | Alert points as fractions | `[0.5, 0.8, 1.0]` | numbers above 0, at most 10 |
| `budg.bill_acct` | Billing account to use (needed only if you have several) | empty | account id or empty |
| `imag.refe` | Image used when `imag.sour` is empty | Google's hello image | image address |
| `imag.sour` | `owner/image:tag` on the public registry; makes a pull-through repo | empty | text or empty |
| `imag.upst` | The public registry address | `https://ghcr.io` | `https://` |
| `serv.mini` | Smallest number of running copies | `0` | 0 to `maxi` |
| `serv.maxi` | Largest number of running copies | `1` | 1 to 10 |
| `serv.cpuz` / `serv.memo` | CPU and memory per copy | `1` / `256Mi` | Cloud Run values |
| `serv.idle` | CPU only while a request runs | `true` | `true`/`false` |
| `serv.conc` | Requests per copy at once | `80` | 1 or more |
| `serv.time` | Request time limit | `30s` | seconds with `s` |
| `serv.publ` | Anyone may call the service (the timer cannot sign in) | `true` | `true`/`false` |
| `serv.ingr` | Who can reach it | `INGRESS_TRAFFIC_ALL` | Cloud Run value |
| `serv.port` | Port the program listens on | `8080` | 1-65535 |
| `serv.role` | The one role the runtime account gets | `roles/logging.logWriter` | role name |
| `tick.path` | Path the timer calls | `/tick` | starts with `/` |
| `tick.prob` | Test the tick path twice during setup | `false` | `true`/`false` |
| `tick.okay` | Answers that count as success | `[200, 202]` | list of numbers |
| `tick.ruid` | Run id used by the test | `probe-run-1` | text |
| `guid.open` | Open the page in the browser | `true` | `true`/`false` |
| `guid.clip` | Copy helper text to the clipboard | `true` | `true`/`false` |
| `guid.poll` | Seconds between checks while waiting | `5` | 1 or more |
| `guid.wait` | Longest wait for one step | `900` | seconds |
| `guid.sign/bill/cons` | Pages to open | Google pages | addresses |
| `http.trys` / `back` / `maxw` | Tries, first pause, longest pause (seconds) | `4` / `2` / `60` | numbers |
| `http.agen` | Name sent to Google | `cloud-house-ggc-run/1` | text |
| `http.maxb` | Biggest answer accepted (bytes) | `4194304` | number |
| `http.lro_msec` / `lro_secs` | Pause between checks of a Google job / longest wait | `3000` / `600` | milliseconds / seconds |
| `limi.reqs` / `vcpu` / `gibs` | Free grant per month (requests, vCPU-seconds, GiB-seconds) | `2000000` / `180000` / `360000` | numbers |
| `limi.warn` | Warn at this percent | `80` | 1-100 |

---

## Input
| Part | Meaning |
|---|---|
| `run` | Plan only; with `--go`, sets everything up |
| `plan` / `status` / `usage` | Read-only views |
| `revoke` | Plan only; with `--go`, removes public access and the login the tool made |
| `--conf PATH` | Use another settings file |

## Output
| Item | Value |
|---|---|
| State | `{home}/.05-cloud-house-secre/ggc-run-state.json` (ids only, no secrets) |
| Log | `{home}/.05-cloud-house-secre/ggc-run-audit.log` (one line per call, secrets masked) |
| Handoff | `{home}/.05-cloud-house-secre/ggc-run-handoff.json` (project, region, service, address, tick address) |

## Files In This Tool
```
00-config.json   — all settings
df-steps.json    — the 12 steps as data
main.zig         — starts the tool
build.zig        — builds the tool and the pretend Google
```
