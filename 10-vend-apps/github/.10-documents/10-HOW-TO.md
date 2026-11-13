# How To

Every task, step by step. See `05-README.md` first. Run the commands from the app folder:
```
cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/github
```

---

## Set it up (first time)
Follow `05-README.md` Quick Start. If a step needs you (for example two-factor sign-in), it says so and stops. Run the same command again afterwards: it picks up where it left off.

---

## Publish a change to GitHub
1. Edit your code in `/home/mai_trang/00_modules/05-cloud-house`. Never edit the copy folder: it is overwritten.
2. Look at what would happen (changes nothing):
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/github/zig-out/bin/github publish --from /home/mai_trang/00_modules/05-cloud-house --root /home/mai_trang/05-cloud-house-synch
```
```
mirror: copied 7 · same 385 · denied 0 · too big 0 · moved to trash 0
dry-run: nothing scanned, committed or pushed. Pass --live to publish.
```
3. Publish for real:
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/github/zig-out/bin/github publish --from /home/mai_trang/00_modules/05-cloud-house --root /home/mai_trang/05-cloud-house-synch --live
```
```
mirror: copied 7 · same 385 · denied 0 · too big 0 · moved to trash 0
workflow: updated .github/workflows/build.yml
scan: 395 files checked, nothing risky
published 754d671
```
If nothing changed it says `nothing to publish`. It always tries the upload, so a second place that was offline catches up.

---

## Copy only (no upload)
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/github/zig-out/bin/github push --from /home/mai_trang/00_modules/05-cloud-house --root /home/mai_trang/05-cloud-house-synch --live
```
Files you removed from your work folder are moved to `~/00_modules/zzzz-delete-force-items/05-cloud-house-synch/`, never deleted.

---

## Make a downloadable release
Pick a new version each time. The cloud then builds every app for Linux and Windows and publishes the files on your repo's Releases page (about 15-20 minutes):
```
cd /home/mai_trang/05-cloud-house-synch && git tag v0.1.0 && git push origin v0.1.0
```

---

## See where setup stands
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/github/zig-out/bin/github plan --root /home/mai_trang/05-cloud-house-synch
```
```
00 [done] Preflight: OS and git
01 [done] Prepare sign-up: free username, strong password
...
19 [done] Final check + report
```

---

## Undo what the app made
Kills the login and secrets the app made. Your repo stays.
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/github/zig-out/bin/github revoke --live --root /home/mai_trang/05-cloud-house-synch
```

---

## If something goes wrong
| You see | Do this |
|---|---|
| `cannot read the email state ... 404` | Add the permissions: `gh auth refresh -h github.com -s user:email,read:user,write:public_key` |
| `the passphrase needs 8 characters or more` | Use a longer passphrase |
| `a key-like or oversized file would be committed` | It found a password or key in a file. Remove it. If the file is harmless, add its exact path to `scan.skip` in `00-config.json` |
| `--from and --root must be two separate folders` | Use a copy folder outside your work folder |
| `--root overlaps the secret folder` | Pick another copy folder; this one would upload your keys |
| `the folder sits inside another git repo` | Use a plain folder, not one inside another repo |
| The cloud build is red and says a file is missing | Add that file's pattern to `push.allo` and publish again |
