# Updates

What changed, newest first.

---

## 2026-11-13
**Added:** login through `glab` (or your own OAuth app id kept in a private file); your GitHub login and token are read from `gh`.
**Changed:** the project can be public, internal or private by a setting. All apps share one private folder, `~/.05-cloud-house-secre/`. The vault is now `gitlab-vault.json`.
**Fixed:** the SSH key path was never filled in; the audit log was written to the wrong folder and lost its first line.

---

## 2026-11-12
**Added:** First release. One command makes your GitLab project, protects it, adds it as a second push address and sets up a self-renewing token for the GitHub mirror job.
