# How To

Run the commands from any folder. `EXE` = `/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/secret-bundle/zig-out/bin/secret-bundle`, `CFG` = `/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/secret-bundle/00-config.json`, `REPO` = your repo folder.

---

## Build it (once per device)
```
cd /home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/secret-bundle && zig build
```

---

## Lock your secrets (the device that holds them)
1. Dry-run: `EXE pack --repo REPO --config CFG`. It lists every file it would lock.
2. Real: `EXE pack --repo REPO --config CFG --go`. Type the passphrase twice.
```
sealed -> REPO/05-cloud-house/secret-bundle.enc (… bytes). Commit it; never share the passphrase through git.
```
3. Your sync uploads the file.

---

## Get the secrets on another device
1. Join the repo and let it sync, so the bundle file arrives.
2. Build the app (above).
3. Look: `EXE unpack --repo REPO --config CFG`. Type the passphrase.
4. Write: `EXE unpack --repo REPO --config CFG --go`.
5. Check: `EXE check --repo REPO --config CFG`. It must say `0 new here · 0 differ`.

---

## See if two devices match
`EXE status --repo REPO --config CFG` on both. The `sha256` line must be identical (same bundle file). `check` proves your files match it.

---

## Change a secret
Change the file on the device that holds it, run `pack --go` again, let it sync, then `unpack --go` elsewhere. The old local copy goes to the trash folder (`unpack.trash`).

---

## Change the passphrase
1. On the device that holds the secrets: `EXE pack --repo REPO --config CFG --go --rekey`. Type the NEW passphrase twice.
2. Let it sync, then on every other device run `unpack --go` with the NEW passphrase.
Without `--rekey` the program refuses to replace a bundle your passphrase cannot open.

---

## If something goes wrong
| You see | Do this |
|---|---|
| `the passphrase is too short` | Use 16 or more characters (`bundle.pass_min`) |
| `the bundle in the repo was made with another passphrase` | Retype the right one. To change it on purpose use `--rekey` (above) |
| `cannot open the bundle` | Wrong passphrase or a damaged file. Retype; else restore the file from git history |
| `no bundle file` | Pull first, or run `pack --go` on the device that holds the secrets |
| `the picked files are over the total cap` | Narrow `pick.*` or raise `pick.total_maxz_mbyt` on purpose |
| `a link sits where a secret file should be` | Move that link away by hand, then run again |
