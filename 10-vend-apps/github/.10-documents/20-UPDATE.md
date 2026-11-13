# Updates

What changed, newest first.

---

## 2026-11-13
**Added:** `publish` (copy, scan, commit and upload in one command), `push` (one-way copy), a release build on version tags, a private ssh config so one upload can reach GitHub, GitLab and Forgejo, and whole-file secret scanning.
**Changed:** the repo is public by a setting. Your login and email moved to a private file. All apps share one private folder, `~/.05-cloud-house-secre/`. A clean copy still tries the upload, so a second place that was offline catches up.
**Releases:** each app is built in its own parallel job and the release opens only when all are attached.
**Safer publish:** before a live publish the app runs every app's tests and stops at the first red one, so half-finished code stays off the public repo. Release downloads now include the license file.
**Safer key:** the SSH key is now a deploy key: it works for this one repo only, so a leak cannot touch your other repos. Set `sshz.kind` to `account` to go back. A key cannot be both, so the app makes a new file, `id_ed25519_deploy`.
**Fixed:** the private ssh config now matches the real host name too (`github.com`, `gitlab.com`). Before, its key rows never matched, so git used your default `~/.ssh` key.
**License:** every app now uses PolyForm Noncommercial 1.0.0 (free for personal use, paid for commercial). The public repo gets a root `LICENSE` and `README.md`.
**Safer:** the copy folder may not overlap your work folder or hold your private folder; private files are owner-only.

---

## 2026-11-12
**Added:** First release. One command sets up a repo with rules, a build check and an SSH key, and can undo what it made.
