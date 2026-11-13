# Render Setup

One command gets you a free Render web service that runs your Trigger image, ready to use as a fallback.
No card needed for the free plan. You do two things by hand, once: sign up, and paste one API key.

---

## What it does
It creates a free web service on Render from a public container image, sets its health check, sends your environment variables from a private vault, and writes the service address to a file the Schedule layer reads. Then it times a cold start so you know how long a sleeping service takes to wake. Run it again any time: it never makes a second copy and never deletes anything.

---

## Requirements
- Windows 10+ or Linux (64-bit)
- A public container image on GitHub's registry (for example `ghcr.io/you/cloud-house-trigger:latest`)
- Nothing else. No install.

---

## Quick Start
1. Open `00-config.json` and set `imag` (under `rend`) to your public image path.
2. Preview. Nothing changes:
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/render/zig-out/bin/render-setup run
```
You see the plan and `hand jobs: 2`.
3. Run it for real:
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/render/zig-out/bin/render-setup run --go
```
It opens the sign-up page, waits for you to type `g`, asks for your API key (hidden), then does the rest. It ends with:
```
== report ==
done: 8  skipped: 1  to-do: 0  hand jobs used: 2
```

---

## Where your secrets go
Your API key and passphrase never touch `00-config.json`. The key lives in an encrypted vault file in your home folder (`.05-cloud-house-secre`). Only you hold the passphrase.

---

## Next
- **`10-HOW-TO.md`** — every step, one tiny action at a time
- **`15-CONFIG.md`** — every setting and file
- **`20-UPDATE.md`** — what changed, by date

---

## License
PolyForm Noncommercial 1.0.0. Free for personal and noncommercial use (hobby, study, research, charity). Using it in a business or for profit needs a paid commercial license: open an issue at https://github.com/maitrang1/05-cloud-house/issues. Full text: `25-LICENSE`.
