# Config Reference

Plain facts: where things go, what the settings do. For steps, see `10-HOW-TO.md`.

---

## The Program
| Item | Value |
|---|---|
| File (Linux) | `/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/zalochat/scrape/zig-out/linux-x86_64/bin/scrape` |
| File (Windows) | `E:\00_modules\05-cloud-house\05-jobs-apps\zalochat\scrape\zig-out\windows-x86_64\bin\scrape.exe` |
| Run | `scrape <command> [--config FILE] [--json]` |
| Data folder | `SCRAPE_HOME`, else the `home` setting, else `.zalochat-scrape` in your home folder |
| Settings file | `--config FILE`, else `SCRAPE_CONFIG`, else `00-config.json` here, else next to the program |
| Built with | Zig 0.16.0, standard library only (the optional personal reader uses Node) |

Exit codes: `0` done · `1` failed · `2` wrong setup or input · `3` blocked, paused, or the key is dead.

---

## Commands
| Command | What it does |
|---|---|
| `state [--cust ID] [--resume]` | Show status; with a customer, their counts and pause state |
| `cust --cust ID` | Create or edit a customer (`--add-url`, `--webhook`, `--vendors on/off`, `--retention-days`, `--daily-cap`) |
| `consent --cust ID --grant/--revoke` | Record the customer's agreement |
| `scan --cust ID [--url U] [--dry-run]` | Collect public pages |
| `rows --cust ID [--since N] [--limit N] [--push]` | Read stored rows, or send the next batch to the webhook |
| `login --cust ID --tier oa/personal` | Connect an Official Account, or a personal account |
| `sync --cust ID --tier oa/articles/mini/personal` | Pull private data (read only) |
| `probe VENDOR URL [--dry-run] [--revive]` | Try one helper service |
| `chan status/proof/scan` | Channel and video pages of other creators (off until a 20-page proof passes) |
| `risk --cust ID [--reset]` | Personal-account safety state |
| `dump --cust ID [--out DIR]` | Export a customer's data |
| `purge --cust ID [--old] [--yes]` | Remove a customer's data (preview without `--yes`) |

---

## Settings (`00-config.json`)
A misspelled name is refused with its line and column. Keys that end in `_env` hold the NAME of an environment variable, never the secret itself.

| Setting | What it does | Default | Allowed |
|---|---|---|---|
| `home` | Data folder | empty (use the rules above) | a folder path |
| `public.user_agent` | The name we send to sites | `zalochat-scrape/0.1 (respects robots.txt)` | text |
| `public.allow_hosts` | Sites we may read | `zalo.me`, `www.zalo.me`, `chat.zalo.me`, `zaloapp.com` | host names |
| `public.gap_ms` | Pause between requests to one site | 3000 | 1 or more |
| `public.jitter_ms` | Random extra pause | 1500 | 0 or more |
| `public.timeout_s` | Give up on a request after | 20 | 1 or more |
| `public.body_cap_kb` | Biggest page we accept | 1024 | 1 or more |
| `public.daily_cap` | Pages per customer per day | 200 | 0 or more |
| `public.robots_ttl_s` | How long a robots answer is reused | 3600 | seconds |
| `public.robots_cap_kb` | Biggest robots file we read | 128 | KB |
| `public.stop_on_block` | Stop the run when a site blocks us | true | true / false |
| `public.retry_5xx` | Retries after a server error | 1 | 0 or more |
| `public.text_cap` | Longest page text kept | 4000 | characters |
| `public.field_cap` | Longest title or description kept | 500 | characters |
| `vendor.file` | The list of helper services | `df-scrape-vendors.json` | a file path |
| `vendor.stop_pct` | Stop using a helper at this share of its monthly credits | 80 | 1 to 100 |
| `vendor.breaker_fails` | Failures in a row that pause a helper | 3 | 1 or more |
| `vendor.breaker_cool_s` | How long a paused helper rests | 300 | seconds |
| `vendor.order` | Which helper to try first | scrapingant, zenrows, scrape-do, scraperapi, firecrawl | helper ids |
| `deliv.retries` | Resends of a failed batch | 3 | 0 or more |
| `deliv.backoff_ms` | First wait before a resend (doubles) | 500 | ms |
| `deliv.secret_env` | Variable holding the signing secret | `SCRAPE_HOOK_SECRET` | a variable name |
| `deliv.sig_header` | Name of the signature header | `x-scrape-signature` | header name |
| `deliv.pull_page` | Rows per batch or page | 100 | 1 or more |
| `secrets.master_env` | Variable holding the 64-character master key | `SCRAPE_MASTER_KEY` | a variable name |
| `oa.api_base` / `oa.oauth_base` | Zalo servers | `https://openapi.zalo.me` / `https://oauth.zaloapp.com` | https addresses |
| `oa.app_id_env` / `oa.app_secret_env` | Variables holding your app ID and secret | `ZALO_APP_ID` / `ZALO_APP_SECRET` | variable names |
| `oa.redirect_uri` | The return address you registered with Zalo | empty (must be set to log in) | an https address |
| `oa.refresh_margin_s` | Renew the access key this long before it ends | 3600 | seconds |
| `oa.page_users` / `oa.page_msgs` | Followers / messages per request | 50 / 10 | 1 or more |
| `oa.max_followers` | Most followers read | 10000 | 1 or more |
| `oa.max_messages` | Most messages read per run | 2000 | 1 or more |
| `oa.max_articles` | Most articles read per run | 500 | 1 or more |
| `oa.call_gap_ms` | Pause between Zalo calls | 500 | ms |
| `oa.paths.*` | The ten Zalo page paths used (authorize, token, info, followers, profile, recent, conversation, quota, articles, article_detail) | Zalo's published paths | paths |
| `legal.retention_days` | Keep private chat rows this long | 90 | days |
| `legal.consent_required` | Refuse private sync without consent | true | true / false |
| `side.enabled` | Allow the personal-account reader | false | true / false |
| `side.node` | The Node program | `node` | a name or path |
| `side.dir` | Folder of the personal reader | `side` | a folder path |
| `side.lease_ttl_s` | How long one computer holds the account | 120 | seconds |
| `side.daily_cap` | Personal-account calls per day | 300 | 1 or more |
| `side.whitelist` | The only reads allowed | account info, friends, groups, group info, group history | read names |
| `side.gap_ms` | Pause between personal calls | 1500 | ms |
| `side.call_timeout_ms` | Give up on one personal call after | 60000 | ms |
| `side.history_count` | Messages asked per group | 50 | 1 or more |
| `side.risk_days` | Clean days that pass the safety drill | 7 | 1 or more |
| `side.max_groups` | Most groups read | 100 | 1 or more |
| `sche.kill_switch` | Stop every run | false | true / false |
| `sche.max_fails` | Failed runs in a row before a customer is paused | 3 | 1 or more |
| `sche.spike_pct` | Alert when today's pages pass this share of the daily average | 300 | percent |
| `watch.ping_env` | Variable holding a health-check web address | `SCRAPE_PING_URL` | a variable name |
| `watch.spike_min` | Smallest daily count that can raise a spike alert | 20 | pages |
| `chan.proof_pages` | Pages a helper must read cleanly before channel and video pages turn on | 20 | 1 or more |
| `chan.pass_pct` | Success share needed | 95 | 1 to 100 |

---

## Input
| Part | Meaning |
|---|---|
| Customer id | Lower-case letters, digits, `_` and `-`, up to 64 characters |
| Zalo page | `https://zalo.me/NAME` (allowed hosts only, port 443) |
| Helper keys | One variable per helper, named in the helper list (for example `ZENROWS_KEY`) |

## Output
| Item | Value |
|---|---|
| Rows | One line per row, in the customer's folder |
| Row fields | customer, public or private, address or key, kind, time, hash, data |
| Webhook | A signed JSON batch: header `x-scrape-signature: sha256=...` and `x-scrape-timestamp` |

## Files In This Tool
```
scrape(.exe)            — the program
00-config.json          — settings
df-scrape-vendors.json  — the helper-service list (add a helper = add a row)
df-hub-jobs.json        — jobs for the automation hub (all start off)
side/                   — the optional personal-account reader
```
Per customer, in the data folder: `cust.json`, `rows.jsonl`, `files/`, `audit.jsonl`, `usage.log`, `secrets.enc` (encrypted).
