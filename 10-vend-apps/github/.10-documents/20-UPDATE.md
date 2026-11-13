# Updates

What changed, newest first.

---

## 2026-11-13
**Added:** `publish` (copy, scan, commit and upload in one command), `push` (one-way copy), a release build on version tags, a private ssh config so one upload can reach GitHub, GitLab and Forgejo, and whole-file secret scanning.
**Changed:** the repo is public by a setting. Your login and email moved to a private file. All apps share one private folder, `~/.05-cloud-house-secre/`. A clean copy still tries the upload, so a second place that was offline catches up.
**Safer:** the copy folder may not overlap your work folder or hold your private folder; private files are owner-only.

---

## 2026-11-12
**Added:** First release. One command sets up a repo with rules, a build check and an SSH key, and can undo what it made.
