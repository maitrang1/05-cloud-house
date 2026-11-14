# Forgejo Setup

One command turns a bare Linux server into a private code home (Forgejo) with a locked-down repo.
No cloud account. No sign-up. Your code stays on your own machine.

---

## What it does
It installs Forgejo on your own Linux server, checks the download is genuine, turns public sign-up off, creates your admin, a private `cloud-house` repo, and adds it as a second place your code is pushed to. Run it twice and nothing breaks.

---

## Requirements
- A Linux server you control (x86_64, systemd). Create it first: that is the only manual job.
- `git` and `ssh-keygen` installed.
- You run the program as `root` on that server.

---

## Quick Start
1. Create `~/.05-cloud-house-secre/forgejo-account.json` with `{"user": "your-name", "mail": "you@example.com"}`.
2. Look before you leap (changes nothing):
```
/home/mai_trang/05-cloud-house/10-vend-apps/forgejo/zig-out/bin/forgejo-setup run
```
3. Run it for real:
```
/home/mai_trang/05-cloud-house/10-vend-apps/forgejo/zig-out/bin/forgejo-setup run --go
```
It asks for a vault passphrase, then prints each step and ends with `done · skipped · to-do · hand jobs used`.

---

## Where secrets go
The access token lives in an encrypted vault file under `~/.05-cloud-house-secre/`. It is never printed, never written to git, never written to the log.

---

## Next
- **`10-HOW-TO.md`** — every command, step by step
- **`15-CONFIG.md`** — every setting and file
- **`20-UPDATE.md`** — what changed, by date

---

## License
PolyForm Noncommercial 1.0.0. Free for personal and noncommercial use (hobby, study, research, charity). Using it in a business or for profit needs a paid commercial license: open an issue at https://github.com/maitrang1/05-cloud-house/issues. Full text: `25-LICENSE`.
