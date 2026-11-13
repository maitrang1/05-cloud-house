# GitHub Setup

One command sets up your GitHub repo with a build check, a safe login and an SSH key. Two more commands keep a clean public copy of your code up to date.
No password is stored in a file. Nothing is ever deleted.

---

## What it does
It checks your GitHub account, makes (or finds) your repo, sets its rules, uploads a key so your computer can push, adds the cloud build, and then keeps a trimmed copy of your code on GitHub up to date. Before every upload it reads your files for passwords and keys and stops if it finds one. Run it twice and nothing breaks.

---

## Requirements
- A GitHub account (or the program helps you through sign-up).
- `git` and `gh` (the GitHub program) installed. `gh` must be logged in.
- An empty folder for the public copy, for example `/home/mai_trang/05-cloud-house-synch`. It must not be inside your work folder.

---

## Quick Start
1. Give `gh` the permissions it needs, once. Approve the code in your browser:
```
gh auth refresh -h github.com -s user:email,read:user,write:public_key
```
2. Put your GitHub name and email in the private file `~/.05-cloud-house-secre/github-account.json` (it is never uploaded):
```
{"logi": "your-github-name", "mail": "you@example.com"}
```
3. Look before you leap (changes nothing):
```
cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/github
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/github/zig-out/bin/github run --root /home/mai_trang/05-cloud-house-synch
```
4. Run it for real. It asks for a vault passphrase (8 or more characters): save it in your password manager.
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/github/zig-out/bin/github run --live --root /home/mai_trang/05-cloud-house-synch
```
It prints each step and ends with `done: 18  skipped: 2  stopped at: (finished)`.

---

## Where secrets go
Your passphrase locks one encrypted file in `~/.05-cloud-house-secre/`. Your login, email, SSH key and logs live in that same private folder. None of it is ever uploaded.

---

## Next
- **`10-HOW-TO.md`** — every task, step by step
- **`15-CONFIG.md`** — every setting and file
- **`20-UPDATE.md`** — what changed, by date

---

## License
PolyForm Noncommercial 1.0.0. Free for personal and noncommercial use (hobby, study, research, charity). Using it in a business or for profit needs a paid commercial license: open an issue at https://github.com/maitrang1/05-cloud-house/issues. Full text: `25-LICENSE`.
