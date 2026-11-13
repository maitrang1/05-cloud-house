# Config Reference

Plain facts: where things go and what every setting does. For steps, see `10-HOW-TO.md`.

---

## The Program
| Item | Value |
|---|---|
| File | `oracle-setup` (`oracle-setup.exe` on Windows) |
| Run | `oracle-setup <command> [--live] [--paid] [--config FILE] [--steps FILE]` |
| Commands | `plan` · `run` · `status` · `drift` · `revoke` · `sshkey FILE` · `vault` · `version` · `help` |
| Default mode | dry-run. Nothing is called or written until you type `--live`. |
| Exit codes | `0` ok · `1` failed · `2` bad command or config · `3` drift found · `4` waiting for you |
| Built with | Zig 0.16.0, standard library only |

---

## Settings (`00-config.json`)
A wrong or unknown setting stops the program and names the line. Every setting must be present.

| Setting | What it does | Default | Allowed |
|---|---|---|---|
| `vers` | Settings format version | `1` | `1` |
| `data.root` | Folder for the vault, state, log and backups. `{home}` means your home folder | `{home}/.05-cloud-house-secre` | any path |
| `data.vaul` · `data.stat` · `data.audi` | File names of the vault, the progress file and the call log | `oracle-vault.json` · `oracle-state.json` · `oracle-audit.log` | file names |
| `data.back` | Backup folder name (inside `data.root`) | `oracle-backup` | folder name |
| `vaul.envz` | Name of the environment variable that holds your vault passphrase | `CLOUD_HOUSE_VAULT_PASS` | a name |
| `vaul.time` · `vaul.memo` · `vaul.para` | Vault lock strength (Argon2id passes, memory in KiB, threads) | `3` · `65536` · `1` | whole numbers above 0 |
| `http.trys` | Tries per call when Oracle says "slow down" | `3` | 1 or more |
| `http.back` · `http.maxw` | First wait and longest wait between tries, in seconds | `2` · `30` | whole numbers |
| `http.agen` | Name the program gives itself to Oracle | `oracle-setup/0.1` | text |
| `http.maxb` | Biggest answer accepted, in bytes | `4194304` | whole number |
| `apis.iden` · `apis.iaas` | Oracle web addresses. `{regi}` becomes your home region | `https://identity.{regi}.oraclecloud.com` · `https://iaas.{regi}.oraclecloud.com` | must contain `{regi}`, must start with `https://` |
| `apis.vers` | Oracle API version | `20160918` | text |
| `urls.sign` · `urls.keys` | Pages the program opens for you | Oracle sign-up · Oracle API keys page | web addresses |
| `keyz.file` | Use your own PEM key file instead of making one. Empty = make one | empty | file path or empty |
| `keyz.tool` | Program that makes the key | `openssl` | program name |
| `keyz.bits` | Key size | `2048` | `2048` or more |
| `keyz.comm` | Label put on the VM login key | `cloud-house` | one word |
| `cred.tena` · `cred.user` · `cred.regi` | Your tenancy id, user id and home region, if you want to skip typing them | empty | text or empty |
| `comp.name` · `comp.desc` | Name and note of the compartment (a folder for your cloud things) | `cloud-house` | text |
| `netw.vcnn` · `netw.vcnc` | Network name and address range | `cloud-house-vcn` · `10.0.0.0/16` | text |
| `netw.subn` · `netw.subc` | Subnet name and range | `cloud-house-sub` · `10.0.0.0/24` | text |
| `netw.igwn` · `netw.routn` · `netw.secn` · `netw.ruln` | Names of the gateway, route table, firewall list and rule label | `cloud-house-…` | text |
| `ingr` | Firewall doors that stay open: a list of `port`, `cidr` (who may enter), `desc` | ssh 22 and app 8080, from anywhere | ports 1..65535 |
| `inst.name` | Name of the VM | `cloud-house-vm` | text |
| `inst.ocpu` · `inst.memg` | Size of a Flex shape (both 0 for a fixed shape); Arm free pool is 2 OCPU / 12 GB | `2` · `12` | at most `quot.ocpm` · `quot.memm` |
| `inst.fall` · `inst.fcpu` · `inst.fmem` | Fallback shape tried when the first is sold out (empty = none) | micro · `0` · `0` | in `inst.free` |
| `inst.shap` | VM type (Arm first: far more headroom, same price: zero) | `VM.Standard.A1.Flex` | must be in `inst.free` unless paid is on |
| `inst.free` | Types that cost nothing | the one micro type | list |
| `inst.imgo` · `inst.imgv` | Operating system and version | `Canonical Ubuntu` · `24.04` | text |
| `inst.boot` | Boot disk size in GB | `50` | 47 or more |
| `inst.user` | Login name shown in the final report | `ubuntu` | text |
| `inst.wait` · `inst.poll` | How long to wait for the VM, and how often to look, in seconds | `600` · `10` | whole numbers |
| `boot.urlz` · `boot.sha2` | Address and sha256 of your app program. Both empty = no app is installed | empty | text |
| `boot.bina` · `boot.svcn` · `boot.svcu` · `boot.args` | Where the app goes on the VM, its service name, the user it runs as, its arguments | `/usr/local/bin/cloud-house-app` · `cloud-house-app` · `chouse` · empty | text |
| `cini` · `unit` | The VM start-up script and service file, line by line | see file | lines |
| `keep.on` | Run a small repeating load so Oracle does not see the VM as idle | `false` | `true` / `false` |
| `keep.duty` · `keep.secs` | Percent busy, and the cycle length in seconds | `25` · `60` | 1..90 · above 0 |
| `kunit` | The lines that install the load timer | see file | lines |
| `paid.okay` · `paid.cap` | Allow a paid VM type, and your monthly cap. Needs `--paid` too | `false` · `0` | cap above 0 when on |
| `quot.warn` | Warn when free quota use reaches this percent | `80` | 1..100 |
| `quot.vmax` · `quot.bmax` | Free limits: VMs and boot-disk GB | `2` · `200` | above 0 |
| `quot.ocpm` · `quot.memm` | Free Arm limits: OCPUs and GB RAM | `2` · `12` | above 0 |
| `guid.open` · `guid.clip` | Open pages and fill the clipboard for you | `true` · `true` | `true` / `false` |
| `guid.poll` · `guid.wait` | How often to look and how long to wait for your hand jobs, in seconds | `5` · `900` | whole numbers |
| `tool.time` | Longest a helper program may run, in seconds | `60` | whole number |

---

## Input
| Part | Meaning |
|---|---|
| `g` | You finished a hand job. Typed at the prompt |
| Region id | Your home region, like `eu-frankfurt-1` |
| Preview block | The lines Oracle shows after you add the key: `user=`, `fingerprint=`, `tenancy=`, `region=` |
| Vault passphrase | 8+ characters. Set once, asked every run (or set the variable named in `vaul.envz`) |

## Output
| Item | Value |
|---|---|
| Progress file | `<data.root>/oracle-state.json` (ids only, no secrets) |
| Vault | `<data.root>/oracle-vault.json` (locked: signing key, VM login key) |
| Call log | `<data.root>/oracle-audit.log` (every web call, secrets masked) |
| Backup | `<data.root>/oracle-backup/oracle-<day>.json` (ids and settings, no secrets) |
| VM login public key | `<data.root>/oracle-ssh.pub` |

## Files In This Tool
```
oracle-setup     the program
00-config.json   every setting above
10-steps.json    the list of steps (names, which are hand jobs)
```
