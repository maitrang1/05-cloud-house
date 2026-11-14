# Secret Bundle

Keeps your shared secrets (API keys, partner keys, tokens) in ONE locked file inside your repo, so every device can get the same secrets by typing one passphrase.
Nothing is sent anywhere. Nothing is ever deleted.

---

## What it does
It finds your secret files (the ones in `.secrets` folders and files such as `*token.json`), locks them with your passphrase into `05-cloud-house/secret-bundle.enc`, and unlocks them on another device. Without the passphrase the file is unreadable, names included.

---

## Requirements
- Your repo folder.
- A passphrase of 16 or more characters. You type it each time. It is never saved.

---

## Quick Start
1. Look first (changes nothing):
```
/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/secret-bundle/zig-out/bin/secret-bundle pack --repo /home/mai_trang/00_modules --config /home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/secret-bundle/00-config.json
```
2. Lock them (you type the passphrase twice, hidden):
```
/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/secret-bundle/zig-out/bin/secret-bundle pack --repo /home/mai_trang/00_modules --config /home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/secret-bundle/00-config.json --go
```
3. Let your normal sync upload the new file.

---

## Features
- Dry-run by default; `--go` to write.
- Same secrets, nothing changed: the file is left alone.
- Wrong passphrase or a damaged file: refused, nothing written.
- A different local file is saved to a trash folder before it is replaced.

---

## License
See `25-LICENSE`.
