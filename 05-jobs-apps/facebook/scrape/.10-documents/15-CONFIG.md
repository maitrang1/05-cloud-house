# Config Reference

Plain facts: where things go and what each setting does. For steps, see `10-HOW-TO.md`.

---

## The Program
| Item | Value |
|---|---|
| File | `scrape` (Linux) · `scrape.exe` (Windows), next to `00-config.json` |
| Run | `scrape <command> [--config FILE] [--json]` |
| Data folder | `SCRAPE_HOME`, or `~/.facebook-scrape` |
| Built with | Zig 0.16.0, standard library only |

A wrong or unknown setting stops the program with the line and column. It never guesses.

## Secrets (environment variables, never in a file)
| Variable | What it is |
|---|---|
| `SCRAPE_MASTER_KEY` | 64 hex characters. Seals the Page tokens. Make one: `openssl rand -hex 32` |
| `FACE_APP_ID` · `FACE_APP_SECRET` | Your Meta app id and secret |
| `FACE_HOOK_VERIFY` | The verify token you typed in the Meta webhook form |
| `SCRAPE_HOOK_SECRET` | Signs the rows we push to your webhook |
| `SCRAPECREATORS_KEY` · `APIFY_TOKEN` · `BRIGHTDATA_KEY` | Vendor keys (the names are set per vendor in `df-scrape-vendors.json`) |
| `SCRAPE_PING_URL` | Optional health-check address, pinged after each run |

## Settings (`00-config.json`)
| Setting | What it does | Default | Allowed |
|---|---|---|---|
| `home` | Data folder. Empty = `SCRAPE_HOME` or `~/.facebook-scrape` | empty | a folder path |
| `market.allow_hosts` | The only Facebook sites a target may point to | facebook.com, www/m/web.facebook.com, l.facebook.com, fb.com, fb.watch | host names |
| `market.user_agent` | Name we send to vendors | `facebook-scrape/0.1` | text |
| `market.timeout_s` | Seconds to wait for a vendor | 30 | 1 or more |
| `market.body_cap_kb` | Largest vendor reply we accept | 4096 | 1 or more |
| `market.daily_cap` | Vendor calls per cust per day (a cust can set its own) | 200 | number |
| `market.text_cap` · `market.field_cap` | Longest text / other field we keep | 4000 · 500 | numbers |
| `market.kinds` | Per kind (page, post, cmnt, item, adlib): where the list sits in a vendor reply, which fields hold the id, and which vendor field names map to our fields | shipped | see the file |
| `vendor.file` | The vendor list file | `df-scrape-vendors.json` | a file |
| `vendor.order` | Vendors to try, first to last (free first) | scrapecreators, apify, brightdata | vendor ids |
| `vendor.stop_pct` | Stop using a vendor at this percent of its monthly budget | 80 | 1 to 100 |
| `vendor.breaker_fails` · `vendor.breaker_cool_s` | A vendor that fails this many times rests this long | 3 · 900 | numbers |
| `deliv.retries` · `deliv.backoff_ms` | Webhook delivery tries and wait | 3 · 500 | numbers |
| `deliv.secret_env` · `deliv.sig_header` | Which variable signs, and the signature header name | `SCRAPE_HOOK_SECRET` · `x-scrape-signature` | text |
| `deliv.pull_page` | Rows per pull | 100 | number |
| `secrets.master_env` | Name of the master key variable | `SCRAPE_MASTER_KEY` | text |
| `graph.base` · `graph.dialog` | Facebook addresses | graph.facebook.com · www.facebook.com | https addresses |
| `graph.version` | Graph version we use. Check Meta's changelog every month | `v26.0` | `vNN.0` |
| `graph.app_id_env` · `graph.app_secret_env` | Names of the app variables | `FACE_APP_ID` · `FACE_APP_SECRET` | text |
| `graph.redirect_uri` | Your callback address for the consent link | empty (must be set) | https address |
| `graph.scopes` | Permissions we ask the Page owner for. Read-only ones only | see file | scope names |
| `graph.deny_scopes` | Write permissions. If one appears in `scopes` the program refuses to start | see file | scope names |
| `graph.page_size` · `graph.max_pages` · `graph.max_rows` | Items per call, calls per list, rows per list | 25 · 20 · 5000 | numbers |
| `graph.call_gap_ms` | Pause between Graph calls | 300 | milliseconds |
| `graph.slow_pct` · `graph.stop_pct` · `graph.slow_ms` | Slow down at this Meta usage percent, stop at the second one, slow by this much | 80 · 95 · 2000 | slow < stop <= 100 |
| `graph.timeout_s` · `graph.body_cap_kb` | Graph wait and reply size | 30 · 4096 | numbers |
| `graph.insights` · `graph.insights_period` | Page statistics to read and their period | media view, post engagements, follows · `day` | Meta metric names |
| `graph.fields` · `graph.paths` | The Graph fields and path for each part (inbox, messages, posts, comments, forms, leads, lives) | shipped | see the file |
| `hook.verify_env` | Variable holding the webhook verify token | `FACE_HOOK_VERIFY` | text |
| `hook.status_url` | Public page where a person checks a deletion request | empty (must be set) | https address |
| `hook.user_keys` | Row fields that hold a Facebook user id (used when a deletion request arrives) | user_id, from_id, psid, sender_id | field names |
| `legal.retention_days` | Own-Page rows older than this are removed by `purge --old` | 90 | days |
| `legal.own_expire_days` | Each own-Page row gets an expiry this many days ahead | 30 | days |
| `legal.consent_required` | No consent, no scan, no sync | true | true / false |
| `sche.kill_switch` | Stops every run at once (a file named `KILL` in the data folder does the same) | false | true / false |
| `sche.max_fails` | A cust is paused after this many failed runs in a row | 3 | number |
| `sche.spike_pct` · `watch.spike_min` | Alert when today's calls pass this percent of the daily average, and at least this many | 300 · 20 | numbers |
| `watch.ping_env` | Variable holding the health-check address | `SCRAPE_PING_URL` | text |

## Input
| Part | Meaning |
|---|---|
| Target | A kind and a public Facebook address: `page=https://www.facebook.com/NAME` |
| Kinds | `page` (Page info) · `post` (posts) · `cmnt` (comments) · `item` (Marketplace listing or search) · `adlib` (Ad Library) |
| Code | The `code=` value from the consent link return address |

## Output
| Item | Value |
|---|---|
| Rows | `<data folder>/cust/<id>/rows.jsonl`, one row per line |
| Raw vendor replies | `<data folder>/cust/<id>/files/` |
| Run log | `<data folder>/cust/<id>/audit.jsonl` (no tokens, no keys) |
| Exit code | 0 ok · 1 failed · 2 usage or setup problem · 3 blocked, limited, dead token or bad signature |

## Files In This Tool
```
scrape / scrape.exe        the program
00-config.json             all settings
df-scrape-vendors.json     the vendor list (add a vendor = add a row)
df-scrape-cust.json        what a cust file looks like
df-scrape-row.json         what a row looks like
df-hub-jobs.json           job rows for the scheduler (all off)
```
