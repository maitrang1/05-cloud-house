# Config Reference

Plain facts: where things go, what the defaults are. For steps, see `10-HOW-TO.md`.

---

## The Program
| Item | Value |
|---|---|
| File | `forgejo-setup` (`.exe` on Windows) |
| Run | `forgejo-setup <run\|status\|drift\|revoke\|vault\|help> [--go]` |
| Default output | text on screen; files under `~/.05-cloud-house-secre/` |
| Built with | Zig 0.16.0, standard library only |
| Exit codes | 0 ok · 1 failed · 2 usage/config · 3 drift · 4 needs a human |

---

## Settings (`00-config.json`)
Every key must be present. An unknown key stops the app and names the line and column.
| Setting | What it does | Default | Allowed |
|---|---|---|---|
| `data.root` | folder for vault, state, log | `{home}/.05-cloud-house-secre` | path |
| `data.vaul` / `stat` / `audi` / `acct` | vault, state, audit, private account file names | `forgejo-vault.json` · `forgejo-state.json` · `forgejo-audit.log` · `forgejo-account.json` | file names |
| `vaul.envz` | env var holding the passphrase | `CLOUD_HOUSE_VAULT_PASS` | name |
| `vaul.time` / `memo` / `para` | vault key cost | 3 · 65536 · 1 | numbers |
| `repo.path` | the git checkout to add the push URL to | `/home/mai_trang/05-cloud-house-synch` (set to your own folder) | path |
| `repo.bran` / `remo` | branch and remote | `main` · `origin` | names |
| `repo.push` | push URL template | `ssh://git@{pubh}:{sshp}/{path}.git` | template |
| `rele.base` / `vers` / `arch` | where and which release | Codeberg · `15.0.5` · `linux-amd64` | text, version required |
| `rele.file` / `sums` / `maxb` | file name, checksum suffix, size cap | `forgejo-{vers}-{arch}` · `.sha256` · 256 MB | text, number |
| `host.bina` | binary path | `/usr/local/bin/forgejo` | path |
| `host.work` / `conf` / `unit` | data dir, app.ini, systemd unit | `/var/lib/forgejo` · `/etc/forgejo/app.ini` · `/etc/systemd/system/forgejo.service` | paths |
| `host.svcu` | service user | `git` | name |
| `host.pubh` | host name the server answers on | `127.0.0.1` | host |
| `host.port` / `sshp` | web port, built-in SSH port | 3000 · 2222 | 1–65535, different |
| `ini` / `unit` | the lines of app.ini and the unit | see file | list of lines; must keep `DISABLE_REGISTRATION = true` |
| `cmds.*` | commands for user, chmod, chown, systemd | see file | command lists |
| `admi.user` / `mail` | admin name and email | empty; the private `forgejo-account.json` (keys `user`, `mail`) fills them | text |
| `toke.name` / `scop` | token name and scopes | `cloud-house` · `write:repository`, `write:user` | text, list |
| `frep.name` / `visi` / `sett` | repo name, visibility, features | `cloud-house` · `private` · all features off | `visi` is `private` or `public`; set when the repo is made, never changed later (a mismatch stops the step) |
| `prot` | branch protection body | push on, force push off | `enable_force_push` must be false |
| `sshz.file` / `titl` | SSH key file and its title | `{home}/.ssh/id_ed25519_forgejo` · `cloud-house` | path, text |
| `tool.*` | git, ssh-keygen, time limit | `git` · `ssh-keygen` · 120 s | names, number |
| `boot.poll` / `wait` | how often and how long to wait for the server | 2 s · 60 s | numbers |
| `http.*` | retries, back-off, size cap | 3 · 2 · 30 · 1 MB | numbers |

## Input
| Part | Meaning |
|---|---|
| `run --go` | really do the setup (without `--go` it only describes) |
| vault passphrase | env var or hidden prompt |

## Output
| Item | Value |
|---|---|
| Vault | `~/.05-cloud-house-secre/forgejo-vault.json` (encrypted; holds the token) |
| State | `~/.05-cloud-house-secre/forgejo-state.json` (ids only, no secret) |
| Audit | `~/.05-cloud-house-secre/forgejo-audit.log` (secrets masked) |

## Free-Tier Settings (added 2026-11-13)
| Setting | What it does | Default |
|---|---|---|
| `ini` (extra sections) | Lean `app.ini`: packages, repo indexer, federation, gravatar, source archives off; memory cache, file sessions, `warn` log | on |
| `unit` (`MemoryMax`, `Nice`) | Caps Forgejo RAM so it cannot starve the other jobs on the VM | `600M` · `5` |
| `bkup.onzz` | Nightly `forgejo dump` timer, one rolling copy (`dump.zip`) | `true` |
| `bkup.svc` · `bkup.tmr` · `bkup.enab` · `bkup.svcf` · `bkup.tmrf` | Lines and paths of the dump service and timer | see file |
| `limi.ramm` · `limi.diskm` · `limi.warn` | VM size the plan assumes (MB) and warn percent | `1024` · `20480` · `80` |

Existing unit files are never overwritten. The dump flags are marked unverified until a live smoke.

## Files In This Tool
```
main.zig               — the commands
config-load.zig        — reads and checks 00-config.json
forg-adapter.zig       — talks to Forgejo
acts-host.zig          — install, app.ini, unit, wait
acts-admin.zig         — admin user, token, revoke
acts-repo.zig          — key, repo, protection, push URL, drift
step-engine.zig        — runs steps, resumes, reports
vault-file.zig         — encrypted secret store
state-file.zig         — what is already done
audit-log.zig          — masked log
http-call.zig          — web calls with retry
tool-exec.zig          — runs git and other tools
os-thin.zig            — the only OS-specific file
line-input.zig         — hidden prompt, g/x keys
date-math.zig          — dates
mock-server.zig        — pretend server for tests
```
