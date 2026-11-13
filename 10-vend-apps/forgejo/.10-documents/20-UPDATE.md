# Updates

What changed, newest first.

---

## 2026-11-12
**Added:** First release. One command installs Forgejo on your Linux server (checksum checked, sign-up off), makes the admin, a private repo and a second push address, and can compare and revoke. Tested on a pretend server only.

---

## Private account file (2026-11-13)
**Changed:** your admin name and email now live in `~/.05-cloud-house-secre/forgejo-account.json`, not in `00-config.json`, so they never reach a public repo. A missing file changes nothing.

---

## Visibility is a setting (2026-11-13)
**Changed:** `frep.visi` takes `private` or `public` (was fixed to private). `repo.path` points at the trimmed copy folder made by the GitHub app's `sync`. An existing repo whose visibility differs from the setting stops the step; it is never changed for you.

---

## First release
**Added:** `run`, `status`, `drift`, `revoke`, `vault`, `help`.
