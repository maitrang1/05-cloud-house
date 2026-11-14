# How To

`EXE` = `/home/mai_trang/05-cloud-house/05-jobs-apps/bundle-secret/zig-out/bin/bundle-secret`, `CFG` = `/home/mai_trang/05-cloud-house/05-jobs-apps/bundle-secret/00-config.json`, `SECRETS` = the folder that holds the secret files (the `00_modules` checkout, e.g. `/home/mai_trang/00_modules`), `VAULT` = the vault repo folder (default `~/05-cloud-house-vault`, set by `bundle.root`).

---

## Build it (once per device)
```
cd /home/mai_trang/05-cloud-house/05-jobs-apps/bundle-secret && zig build
```

---

## Set up the vault repo (once)
1. Make a private repo on GitHub, for example `05-cloud-house-vault`:
```
gh repo create 05-cloud-house-vault --private --clone
```
(run it in `~`, or clone it to `VAULT` yourself.)
2. Turn on the guards for that repo; it may then hold only the bundle and a README:
```
bash /home/mai_trang/05-cloud-house/setup-git.sh VAULT --only '^(bundle-secret\.enc|README\.md|\.hooks-local\.conf)$'
```
3. Give each device access to this repo only (its own deploy key; read-only if the device never locks secrets).

---

## Everyday: two commands (they do the git for you)
1. **Catch up this device:** `EXE fetch --repo SECRETS --config CFG --go`. It pulls the vault repo and writes new secrets. A local file that differs is KEPT (exit 3) and listed.
2. **Share a change:** `EXE ship --repo SECRETS --config CFG --go`. It locks your secrets, commits only the bundle file and pushes. It refuses (exit 3) when another device shipped a newer bundle: run `fetch --go` first.
3. **Take the bundle's value over a local edit:** `EXE fetch --repo SECRETS --config CFG --go --replace`. Your old copy goes to the trash folder first.
Both commands are dry-runs without `--go`. Run `ship` only on the one device where you edit secrets. The vault repo must follow a remote branch (`git push -u origin main` once).
Saved logins (`*session*`) are not shared: each device logs in by itself. Refreshed tokens (`pick.seed_only`) are copied to a new device once and then left alone, so they never show as a difference.
The manual steps below do the same with more control.

---

## Token files (re-authorize or revoke)
Token files (`*token.json`, `pick.seed_only`) are copied to a new device once, then each device keeps and refreshes its own. Two cases need `--reseed`:
1. **You re-authorized on one device** (new login for a Google or Facebook token): there run `EXE ship --repo SECRETS --config CFG --go --reseed`. It puts that device's token files into the bundle.
2. **A token was revoked or replaced and another device still has the old one:** there run `EXE fetch --repo SECRETS --config CFG --go --reseed`. It takes the bundle's token files over this device's; your old copy goes to the trash first.
Without `--reseed` these files are never compared and never make a new bundle.

---

## Lock your secrets (the device that holds them)
1. Dry-run: `EXE pack --repo SECRETS --config CFG`. It lists every file it would lock.
2. Real: `EXE pack --repo SECRETS --config CFG --go`. Type the passphrase twice.
```
sealed -> VAULT/bundle-secret.enc (… bytes). Commit and push it in that folder; never share the passphrase through git.
```
3. Upload it:
```
git -C VAULT add -A && git -C VAULT commit -m "update bundle" && git -C VAULT push
```

---

## Get the secrets on another device
1. Clone the vault repo to `VAULT`, or update it: `git -C VAULT pull --ff-only`.
2. Build the app (above).
3. Look: `EXE unpack --repo SECRETS --config CFG`. Type the passphrase.
4. Write: `EXE unpack --repo SECRETS --config CFG --go`.
5. Check: `EXE check --repo SECRETS --config CFG`. It must say `0 new here · 0 differ`.

---

## See if two devices match
`EXE status --repo SECRETS --config CFG` on both. The `sha256` line must be identical (same bundle file). `check` proves your files match it.

---

## Change a secret
Change the file on the device that holds it, run `pack --go` again, push the vault repo, then `pull` and `unpack --go` elsewhere. The old local copy goes to the trash folder (`unpack.trash`).

---

## Save the passphrase on this device (optional)
So you need not type it each time:
1. `EXE keep-pass --repo SECRETS --config CFG`. Type the passphrase twice (hidden). If a bundle exists, it must open with it, or nothing is saved.
2. It writes `~/.05-cloud-house-secre/05-cloud-house-vault.pass` (owner-only). The program refuses that file if other users can read it (`chmod 600`).
3. **Also keep one copy of the passphrase offline** (password manager or paper). If this disk dies, the bundle cannot be opened without it.
The file never goes in git (the guards block `*.pass`) and is not synced. Each device makes its own. To stop using it, set `bundle.pass_file` to `""` in `00-config.json`, or move the file away.

---

## Change the passphrase
1. On the device that holds the secrets: `EXE pack --repo SECRETS --config CFG --go --rekey`. Type the NEW passphrase twice.
2. Push the vault repo, then on every other device pull and run `unpack --go` with the NEW passphrase.
Without `--rekey` the program refuses to replace a bundle your passphrase cannot open.

---

## If something goes wrong
| You see | Do this |
|---|---|
| `the passphrase is too short` | Use 16 or more characters (`bundle.pass_min`) |
| `the bundle folder is not a git checkout` | Clone the vault repo into `VAULT` first, or set `bundle.root` / `--bundle-root` |
| `the bundle in the repo was made with another passphrase` | Retype the right one. To change it on purpose use `--rekey` (above) |
| `the passphrase file can be read by other users` | `chmod 600` that file, or move it away and run `keep-pass` again |
| `cannot open the bundle` | Wrong passphrase or a damaged file. Retype; else restore the file from git history |
| `this device is behind the vault repo` | `fetch --go` first (add `--replace` to take the bundle's value over a local edit), then `ship` |
| `the vault repo has other changes` | Only the bundle file may differ. Commit or restore the other changes by hand |
| `git failed` | Network, or no git login or deploy key for the vault repo. The line below it is git's own message |
| `no bundle file` | Pull the vault repo first, or run `pack --go` on the device that holds the secrets |
| `the picked files are over the total cap` | Narrow `pick.*` or raise `pick.total_maxz_mbyt` on purpose |
| `a link sits where a secret file should be` | Move that link away by hand, then run again |
