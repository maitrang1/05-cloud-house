# Updates

What changed, newest first.

---

## 2026-11-14
**Added:** first version. `pack`, `unpack`, `check`, `status`. Locks your secret files into one file with a passphrase (Argon2id + AES-256-GCM), refuses unsafe paths, saves a replaced local file to a trash folder, leaves the file alone when nothing changed.
**Safer:** a bundle another passphrase made is never replaced by accident (`--rekey` to do it on purpose).
**Tested:** 19 unit tests and a two-device run in scratch folders (22 checks). Not run on Windows or macOS.
