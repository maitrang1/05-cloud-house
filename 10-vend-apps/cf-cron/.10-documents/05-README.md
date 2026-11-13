# Cloudflare Cron Setup

One command gets you a free Cloudflare Worker that pings your Trigger every few minutes. It is the last-resort tick of the Schedule layer.
No card needed. You do two things by hand, once: sign up, and paste one API token.

---

## What it does
It uploads a tiny Worker to your Cloudflare account, turns on its free `workers.dev` address, sets one cron trigger (every 5 minutes by default), and writes the result to a file the Schedule layer reads. The Worker only calls your Trigger address. Run it again any time: it never makes a second copy and never deletes anything.

---

## Requirements
- Windows 10+ or Linux (64-bit)
- Your Trigger address (for example `https://cloud-house-trigger.onrender.com`)
- Nothing else. No install, no Node.

---

## Quick Start
1. Open `00-config.json` and set `url` (under `trig`) to your Trigger address.
2. Preview. Nothing changes:
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cf-cron/zig-out/bin/cf-cron-setup run
```
You see the plan and `hand jobs: 2`.
3. Run it for real:
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cf-cron/zig-out/bin/cf-cron-setup run --go
```
It opens the sign-up page, waits for you to type `g`, asks for your API token (hidden), then does the rest. It ends with:
```
== report ==
done: 10  skipped: 0  to-do: 0  hand jobs used: 2
```

---

## Where your secrets go
Your API token and passphrase never touch `00-config.json`. They live in an encrypted vault file in your home folder (`.05-cloud-house-secre`). Only you hold the passphrase. The optional tick secret goes in the same vault.

---

## Next
- **`10-HOW-TO.md`** — every step, one tiny action at a time
- **`15-CONFIG.md`** — every setting and file
- **`20-UPDATE.md`** — what changed, by date

---

## License
PolyForm Noncommercial 1.0.0. Free for personal and noncommercial use (hobby, study, research, charity). Using it in a business or for profit needs a paid commercial license: open an issue at https://github.com/maitrang1/05-cloud-house/issues. Full text: `25-LICENSE`.
