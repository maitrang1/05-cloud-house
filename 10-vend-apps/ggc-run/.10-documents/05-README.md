# Ggc Run

Sets up a small Google Cloud Run service for you, with a spending alert, in one command.
No cloud account of ours, no extra install except Google's own `gcloud` login tool (used once).

---

## What it does
Google Cloud Run runs a small program only when someone calls it, so it costs nothing while idle. This tool creates the Google project, links your billing card, turns on what is needed, sets spending alerts at 50%, 80% and 100%, makes the service (at most 1 copy, off when idle), and writes down the web address that the timer service should call. You press three buttons by hand, once. Everything else is automatic and safe to run again.

---

## Requirements
- Windows, Linux or macOS.
- A Google account and a payment card (Google asks for one, even for the free tier).
- Google's `gcloud` tool, installed once: https://cloud.google.com/sdk/docs/install

---

## Quick Start
1. Look at the plan first. Nothing changes:
```
/home/mai_trang/05-cloud-house/10-vend-apps/ggc-run/zig-out/bin/ggc-run run
```
You see the 12 steps and `hand jobs in the list: 3`.

2. Run it for real:
```
/home/mai_trang/05-cloud-house/10-vend-apps/ggc-run/zig-out/bin/ggc-run run --go
```
3. When it opens a page, do what the three lines say, then wait. It notices on its own, or you type `g`.

The last lines show the report:
```
== report ==
done: 10  skipped: 2  to-do: 0  hand jobs used: 1
```

---

## Where Output Goes
Everything the tool remembers is in the `.05-cloud-house-secre` folder inside your home folder. It never holds a password or key. The web address for the timer service is in `ggc-run-handoff.json`.

---

## Next
- **`10-HOW-TO.md`** — every step and option, one tiny step at a time
- **`15-CONFIG.md`** — every setting in `00-config.json`
- **`20-UPDATE.md`** — what changed, by date

---

## License
PolyForm Noncommercial 1.0.0. Free for personal and noncommercial use (hobby, study, research, charity). Using it in a business or for profit needs a paid commercial license: open an issue at https://github.com/maitrang1/05-cloud-house/issues. Full text: `25-LICENSE`.
