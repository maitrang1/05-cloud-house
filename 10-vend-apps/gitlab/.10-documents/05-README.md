# GitLab Setup

One command makes a free GitLab copy of your code that follows your GitHub repo. A safe login, an SSH key and a push token that renews itself.
No password is stored. Nothing is ever deleted.

---

## What it does
It finds your GitHub login, helps you sign up on GitLab (you press the buttons), makes your project with every feature you do not need turned off, protects the main branch, adds GitLab as a second place your code is pushed to, and sets up a token so GitHub can keep GitLab up to date. Run it twice and nothing breaks.

---

## Requirements
- Your GitHub repo set up first (see the GitHub app). `gh` logged in.
- `git` and `ssh-keygen` installed.
- To log in to GitLab: either `glab` (GitLab's program) installed, or your own GitLab OAuth app id (see `10-HOW-TO.md`).
- The public copy folder from the GitHub app, for example `/home/mai_trang/05-cloud-house-synch`.

---

## Quick Start
1. Look before you leap (changes nothing):
```
cd /home/mai_trang/05-cloud-house/10-vend-apps/gitlab
/home/mai_trang/05-cloud-house/10-vend-apps/gitlab/zig-out/bin/gitlab-setup run
```
2. Run it for real. It asks for a vault passphrase (8 or more characters): save it in your password manager.
```
/home/mai_trang/05-cloud-house/10-vend-apps/gitlab/zig-out/bin/gitlab-setup run --go
```
It stops when it needs you (sign-up, email, login), says exactly what to do, and you run the same command again.

---

## Where secrets go
Your passphrase locks one encrypted file in `~/.05-cloud-house-secre/`. The GitLab token and the audit log live there too. None of it is ever uploaded.

---

## Next
- **`10-HOW-TO.md`** — every task, step by step
- **`15-CONFIG.md`** — every setting and file
- **`20-UPDATE.md`** — what changed, by date

---

## License
PolyForm Noncommercial 1.0.0. Free for personal and noncommercial use (hobby, study, research, charity). Using it in a business or for profit needs a paid commercial license: open an issue at https://github.com/maitrang1/05-cloud-house/issues. Full text: `25-LICENSE`.
