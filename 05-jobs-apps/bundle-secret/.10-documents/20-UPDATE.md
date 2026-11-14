# Updates

What changed, newest first.

---

## 2026-11-14
**Added:** first version. `pack`, `unpack`, `check`, `status`. Locks your secret files into one file with a passphrase (Argon2id + AES-256-GCM), refuses unsafe paths, saves a replaced local file to a trash folder, leaves the file alone when nothing changed.
**Sessions not shared:** saved logins (`*session*`, `pick.skip`) stay per device; a login on two machines can make Facebook or Zalo flag the account.
**`--reseed`:** after you re-authorize a token on one device, `ship --reseed` publishes it; on a device that has an old or revoked token, `fetch --reseed` takes the bundle's copy (old copy to the trash). Without it token files are never compared.
**Seed-only files:** tokens a program refreshes by itself (`*token.json`, `pick.seed_only`) are copied to a new device once, then never compared or replaced, and a refreshed copy no longer makes a new bundle.
**Fetch and ship:** `fetch --go` pulls the vault repo and writes new secrets (a local file that differs is kept). `ship --go` locks, commits only the bundle and pushes, and refuses when another device shipped a newer bundle. Both are dry-runs without `--go`.
**Passphrase file:** new `keep-pass` saves the passphrase to an owner-only file on this device (checked against the bundle first), so you need not type it. The program refuses the file if others can read it. Keep one offline copy too.
**Own repo:** the bundle now lives in its own small private repo (`bundle.root`, default `~/05-cloud-house-vault`), not in your code repo. The vault repo accepts only the bundle and a README.
**Renamed:** `secret-bundle` is now `bundle-secret` (file `bundle-secret.enc`, env `BUNDLE_SECRET_PASS`).
**Safer:** a bundle another passphrase made is never replaced by accident (`--rekey` to do it on purpose).
**Tested:** 34 unit tests and a two-device, two-repo run in scratch folders (51 checks). Not run on Windows or macOS.
