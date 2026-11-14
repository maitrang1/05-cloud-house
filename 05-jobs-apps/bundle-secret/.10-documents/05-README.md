# Bundle Secret

Keeps your shared secrets (API keys, partner keys, tokens) in ONE locked file inside a small private repo, so every device can get the same secrets by typing one passphrase.
Nothing is sent anywhere by this program. Nothing is ever deleted.

---

## What it does
It finds your secret files (the ones in `.secrets` folders and files such as `*token.json`), locks them with your passphrase into `bundle-secret.enc`, and unlocks them on another device. Without the passphrase the file is unreadable, names included. The file lives in its own private repo (default folder `~/05-cloud-house-vault`), never in your code repo and never in the public copy.

---

## Requirements
- Your code repo folder (where the secrets are).
- A private git repo for the bundle, cloned to `~/05-cloud-house-vault` (one-time, see `10-HOW-TO.md`).
- A passphrase of 16 or more characters. You type it, or save it once on a device with `keep-pass` (owner-only local file, never in git).

---

## Quick Start
1. Look first (changes nothing):
```
/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/bundle-secret/zig-out/bin/bundle-secret pack --repo /home/mai_trang/00_modules --config /home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/bundle-secret/00-config.json
```
2. Lock them (you type the passphrase twice, hidden):
```
/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/bundle-secret/zig-out/bin/bundle-secret pack --repo /home/mai_trang/00_modules --config /home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/bundle-secret/00-config.json --go
```
3. Upload the file from the vault folder (see `10-HOW-TO.md`).

---

## Features
- Dry-run by default; `--go` to write.
- Same secrets, nothing changed: the file is left alone.
- Wrong passphrase or a damaged file: refused, nothing written.
- A bundle made with another passphrase is never replaced by accident.
- A different local file is saved to a trash folder before it is replaced.
- `fetch` and `ship` do the git for you: catch up, or share a change, in one command each.

---

## License
See `25-LICENSE`.
