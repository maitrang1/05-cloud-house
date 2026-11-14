# Config Reference

Plain facts. All settings live in `00-config.json` next to the program (pass `--config <path>` from another folder). An unknown or wrong setting is refused with its line and column.

---

## The Program
| Item | Value |
|---|---|
| File | `bundle-secret` (`.exe` on Windows) |
| Run | `bundle-secret <pack\|unpack\|check\|fetch\|ship\|keep-pass\|status\|version\|help> --repo <folder> [flags]` |
| Flags | `--repo` · `--config` · `--home` · `--bundle-root` · `--go` · `--rekey` (pack, ship: replace a bundle another passphrase made) · `--replace` (fetch: replace a differing local file) · `--reseed` (token files in `pick.seed_only`: pack/ship publish this device's copy, fetch/unpack take the bundle's copy) |
| Exit codes | 0 ok · 1 failed · 2 usage or config · 3 `check` found a difference, `fetch` kept a local file, or `ship` is behind |
| Built with | Zig 0.16.0, standard library only |

---

## Settings
| Key | What | Default |
|---|---|---|
| `pick.dirs` | folder names whose files are picked | `[".secrets"]` |
| `pick.files` | file patterns picked anywhere (`*` = any run) | `*token.json`, `*client_secret.json`, `*credentials.json` |
| `pick.skip_dirs` | folder names never entered | `.git`, `zig-out`, `.zig-cache`, `node_modules`, `zzzz-delete-force-items` |
| `pick.skip_markers` | a folder holding one of these files is a browser profile and is skipped | `Local State`, `Preferences` |
| `pick.skip` | path patterns to leave out. Sessions (saved logins) are per device, so they are not shared | `*session*` |
| `pick.seed_only` | files a program rewrites by itself (refreshed tokens). A new device gets them once; after that they are never compared or replaced, and a refreshed copy never makes a new bundle. `--reseed` overrides this on purpose | `*token.json` |
| `pick.file_maxz_kbyt` | biggest file picked (KB) | 256 |
| `pick.total_maxz_mbyt` | biggest bundle (MB); more is refused | 64 |
| `bundle.root` | folder that holds the bundle (the vault repo). `{home}` = your home. Empty = the repo being scanned. Must be empty, start with `{home}`, or be absolute | `{home}/05-cloud-house-vault` |
| `bundle.path` | the bundle file name, relative to `bundle.root` | `bundle-secret.enc` |
| `bundle.need_git` | refuse to write the bundle unless `bundle.root` is a git checkout (has `.git`) | `true` |
| `bundle.pass_file` | local file that holds the passphrase (`keep-pass` writes it, owner-only). Empty = never use a file | `{home}/.05-cloud-house-secre/05-cloud-house-vault.pass` |
| `bundle.pass_envz` | env variable that may hold the passphrase | `BUNDLE_SECRET_PASS` |
| `bundle.pass_min` | shortest passphrase for `pack` | 16 |
| `git.bin` | the git program | `git` |
| `git.timeout_secs` | give up on one git command after this many seconds | 120 |
| `fetch.on_differ` | `keep` leaves a local file that differs; `replace` takes the bundle's value (old copy to the trash) | `keep` |
| `ship.message` | the commit message `ship` uses | `update bundle` |
| `state.file` | remembers which bundle this device last absorbed (so `ship` can tell it is behind) | `{home}/.05-cloud-house-secre/bundle-secret-state.json` |
| `argon.time` / `argon.memo_kbyt` / `argon.para` | lock cost | 3 / 65536 / 1 |
| `unpack.file_mode` | mode of restored files (owner only) | `600` |
| `unpack.trash` | where a replaced local file is saved (`{home}` = your home) | `{home}/.05-cloud-house-secre/bundle-trash` |

---

## Files
| What | Where |
|---|---|
| The bundle | `<bundle.root>/<bundle.path>` (commit and push it in the vault repo) |
| Old local copies | `unpack.trash/<yyMMdd_HHmmss>/<path>` (outside both repos, never committed) |
| Sync state | `state.file` (one line, the bundle's sha256; written by `pack --go`, `unpack --go`, `fetch --go`, `ship --go`) |
| Passphrase | first found: the env variable (`bundle.pass_envz`), then `bundle.pass_file` (owner-only), then typed hidden. Never in git |
