# Config Reference

Plain facts: where things go, what the defaults are. For steps, see `10-HOW-TO.md`.

---

## The Program
| Item | Value |
|---|---|
| File | `github` (`.exe` on Windows) |
| Run | `github <plan\|run\|status\|push\|publish\|revoke\|version\|help> [flags]` |
| Flags | `--config` · `--steps` · `--home` · `--root` · `--from` · `--live` |
| Default output | text on screen; files under `~/.05-cloud-house-secre/` |
| Built with | Zig 0.16.0, standard library only |
| Exit codes | 0 ok · 1 failed · 2 usage/config · 3 secret found · 4 waiting on a human |

---

## Settings (`00-config.json`)
Every key has a default. An unknown key stops the app and names the line and column. Your login and email do not go here.
| Setting | What it does | Default | Allowed |
|---|---|---|---|
| `data.root` | private folder | `{home}/.05-cloud-house-secre` | path |
| `data.acct` / `stat` / `vaul` / `audi` / `keys` / `host` | file names in that folder | `github-account.json` · `github-state.json` · `github-main.vault` · `github-audit.jsonl` · `github-keys` · `github-known_hosts` | plain names |
| `auth.mode` | how it logs in | `gh` | `gh`, `device` |
| `auth.scop` | permissions asked | `repo workflow read:user user:email write:public_key` | text |
| `repo.name` / `visi` | repo name and visibility | `05-cloud-house` · `public` | `visi`: `public`, `private` |
| `repo.bran` / `remo` | branch and remote | `main` · `origin` | names |
| `repo.comm_text` / `publ_text` | commit messages | `first commit` · `sync from the work tree` | text |
| `repo.nest_okay` | allow a repo inside another repo | `false` | true, false |
| `tool.gitz` / `ghcl` | programs to run | `git` · `gh` | names or paths |
| `sshc.file` / `hosts` | private ssh config and one row per git host (`name`, `host`, `port`, `user`, `key`) | GitHub, GitLab, Forgejo rows | `key` may use `{keys}`, `{keyz}`, `{home}` |
| `sshz.keyz_name` / `titl` | SSH key file name and its title on GitHub | `id_ed25519_deploy` · `cloud-house` | text |
| `sshz.kind` | where the key lives: `deploy` = this one repo only (safer), `account` = your whole GitHub account | `deploy` | deploy, account |
| `file.igno` / `attr` | lines for `.gitignore` and `.gitattributes` | see file | lists |
| `scan.name` / `mark` | file names and text shapes that count as secrets | see file | lists |
| `scan.skip` | exact paths the scan ignores (known false alarms) | 8 test files | list |
| `scan.wind_kbyt` / `file_maxz_mbyt` | read window, biggest file | 512 · 100 | numbers |
| `push.skip_dirs` | folders never copied | `.git`, `.github`, `zig-out`, `node_modules`, `.10-docs`, … | names |
| `push.allo` / `deny` | files that may be copied / never copied | source, config templates, docs, root `LICENSE` + `README.md` | patterns |
| `task.test_cmd` / `build_opt` / `tmos_secs` / `retr` | the local `test` command, the `-Doptimize` value of `build`, time limit per job, retries of a red job (0..3) | `zig build test` · `ReleaseSafe` · 900 · 1 | list, text, seconds, number |
| `task.edit_skip` | files `--app-edit` ignores when it checks whether an app changed (docs) | `*.10-documents/*` | patterns |
| `data.seen` | private file with each app's last green hash (never synced) | `github-task.seen` | file name |
| `push.keep` | files in the copy the mirror never moves | `.gitignore`, `.gitattributes` | patterns |
| `push.trash` | where removed files go | `{home}/00_modules/zzzz-delete-force-items/05-cloud-house-synch` | path |
| `rule.*` | branch rule: block deletion, block force push | on | true, false |
| `ciiz.*` | cloud flows, one file per app in `dir_path`: runner (`runs_on`, 15-minute limit on slim runners), timeout, Zig version, release job (`rele_runs_on`, `rele_tmos_mins`, `rele_targets`); `drop` lists old workflow files to move to the trash | see file | see file |
| `ghcr.onzz` | check for a container image | `false` | true, false |
| `mirr` | extra git hosts to push to | none | rows |
| `vaul.*` | passphrase variable and lock cost | `CLOUD_HOUSE_VAULT_PASS` · 3 · 65536 · 1 | name, numbers |
| `http.*` · `guid.*` · `osiz.*` · `sign.*` · `warn.*` | timeouts, waits, browser and clipboard help, sign-up pages, free-tier warnings | see file | numbers, text |

## Files
| File | Where | Holds |
|---|---|---|
| `github-account.json` | `~/.05-cloud-house-secre/` | your login and email (owner-only) |
| `github-main.vault` | same | the encrypted vault |
| `github-state.json` | same | which steps are done |
| `github-audit.jsonl` | same | one line per action, secrets hidden |
| `github-keys/` | same | your SSH key |
| `github-ssh_config` | same | which key goes with which git host |
