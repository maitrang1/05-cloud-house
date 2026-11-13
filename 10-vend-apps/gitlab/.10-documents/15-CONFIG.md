# Config Reference

Plain facts: where things go, what the defaults are. For steps, see `10-HOW-TO.md`.

---

## The Program
| Item | Value |
|---|---|
| File | `gitlab-setup` (`.exe` on Windows) |
| Run | `gitlab-setup <run\|status\|drift\|rotate\|revoke\|drill\|vault\|help> [--go]` |
| Default output | text on screen; files under `~/.05-cloud-house-secre/` |
| Built with | Zig 0.16.0, standard library only |
| Exit codes | 0 ok · 1 failed · 2 usage/config · 3 drift · 4 needs a human |

---

## Settings (`00-config.json`)
Every key must be present. An unknown key stops the app and names the line and column. Your GitLab name and OAuth app id do not go here.
| Setting | What it does | Default | Allowed |
|---|---|---|---|
| `data.root` | private folder | `{home}/.05-cloud-house-secre` | path |
| `data.vaul` / `stat` / `audi` / `acct` | vault, state, audit, private account file names | `gitlab-vault.json` · `gitlab-state.json` · `gitlab-audit.log` · `gitlab-account.json` | file names |
| `vaul.*` | passphrase variable and lock cost | `CLOUD_HOUSE_VAULT_PASS` · 3 · 65536 · 1 | name, numbers |
| `repo.path` | the copy folder that gets the extra push URL | `{home}/05-cloud-house-synch` | path |
| `repo.bran` / `remo` | branch and remote | `main` · `origin` | names |
| `gitl.host` / `webz` / `apiz` / `oaut` | GitLab addresses | gitlab.com | https addresses |
| `gitl.user` | your GitLab name | empty (the private account file fills it) | text |
| `gitl.proj` / `visi` | project name and visibility | `cloud-house` · `public` | `visi`: `private`, `internal`, `public` |
| `gitl.push` / `sign` | push URL and sign-up page templates | see file | templates |
| `gitl.sett` | project features, all switched off | see file | GitLab project settings |
| `gith.*` | the GitHub side: secret and variable names, workflow file and template, wait | `GITLAB_MIRROR_TOKEN` · `.github/workflows/mirror.yml` | text, number |
| `oaut.clid` / `scop` | your OAuth app id (private account file) and its scope | empty · `api` | text |
| `logi.orde` | reserved, not used yet | `vault`, `devi`, `glab` | list |
| `tool.*` | programs to run | `git` · `ssh-keygen` · `ssh` · `glab` · `gh` · 120 s | names, number |
| `glab.*` / `ghcl.*` | the arguments for `glab` and `gh` (`{host}` is filled in) | see file | argument lists |
| `sshz.file` / `titl` | SSH key file and its title | `{home}/.ssh/id_ed25519_gitlab` · `cloud-house` | path, text |
| `prot.*` | who may push and merge to `main` | 30 · 40 · no force push | `forc` must be false |
| `toke.*` | the push token: name, scope, role, days, renew margin | `mirror` · `write_repository` · 30 · 90 · 14 | text, numbers |
| `guid.*` · `http.*` · `limi.*` | waits, retries, free-tier caps and warnings | see file | numbers |

## Files
| File | Where | Holds |
|---|---|---|
| `gitlab-account.json` | `~/.05-cloud-house-secre/` | your GitLab name and OAuth app id (owner-only) |
| `gitlab-vault.json` | same | the encrypted vault |
| `gitlab-state.json` | same | which steps are done |
| `gitlab-audit.log` | same | one line per action, secrets hidden |
| `~/.ssh/id_ed25519_gitlab` | your home | the SSH key for GitLab |
