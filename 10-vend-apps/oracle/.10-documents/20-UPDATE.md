# Updates

What changed, newest first.

---

## 2026-11-13
**Added:** First release. Sets up an Oracle Cloud Always Free Linux computer: network, firewall, the computer itself, a login key, a backup of your settings and a final report with your free-quota use.
**Added:** `plan`, `run` (practice by default, `--live` to do it), `status`, `drift`, `revoke`, `sshkey`, `vault`.
**Added:** The program never deletes anything in the cloud. It refuses paid computer types unless you allow it twice (setting and `--paid`).
**Known:** Tested against a pretend Oracle only. The first run on your real account is the live test.
