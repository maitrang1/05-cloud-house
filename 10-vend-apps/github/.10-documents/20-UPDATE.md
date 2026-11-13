# Updates

What changed, newest first.

---

## 2026-11-13
**Added:** `publish` (copy, scan, commit and upload in one command), `push` (one-way copy), a release build on version tags, a private ssh config so one upload can reach GitHub, GitLab and Forgejo, and whole-file secret scanning.
**Changed:** the repo is public by a setting. Your login and email moved to a private file. All apps share one private folder, `~/.05-cloud-house-secre/`. A clean copy still tries the upload, so a second place that was offline catches up.
**Separate flows per app:** every app now has its own cloud workflow file. A push runs only the tests of the apps whose folder changed; a tag like `github-v1.2.3` builds only that app for Linux and Windows and publishes its own release (license file inside). The old shared build and the all-apps tag are gone (`v0.1.1` stays as the old release).
**Local test and build:** `github test --app <name>` and `github build --app <name> [--target windows]`, one app at a time; nothing runs unless you name an app (`--app-all` forces every app; `--app-edit` runs only the apps changed since their last green run). `publish` no longer runs tests.
**Safer key:** the SSH key is now a deploy key: it works for this one repo only, so a leak cannot touch your other repos. Set `sshz.kind` to `account` to go back. A key cannot be both, so the app makes a new file, `id_ed25519_deploy`.
**Fixed:** the private ssh config now matches the real host name too (`github.com`, `gitlab.com`). Before, its key rows never matched, so git used your default `~/.ssh` key.
**License:** every app now uses PolyForm Noncommercial 1.0.0 (free for personal use, paid for commercial). The public repo gets a root `LICENSE` and `README.md`.
**Safer:** the copy folder may not overlap your work folder or hold your private folder; private files are owner-only.

---

## 2026-11-12
**Added:** First release. One command sets up a repo with rules, a build check and an SSH key, and can undo what it made.
