# Config Reference

Plain facts. All settings live in `00-config.json` next to the program (pass `--config <path>` from another folder). An unknown or wrong setting is refused with its line and column.

---

## The Program
| Item | Value |
|---|---|
| File | `secret-bundle` (`.exe` on Windows) |
| Run | `secret-bundle <pack\|unpack\|check\|status\|version\|help> --repo <folder> [flags]` |
| Flags | `--repo` · `--config` · `--home` · `--go` · `--rekey` (pack: replace a bundle another passphrase made) |
| Exit codes | 0 ok · 1 failed · 2 usage or config · 3 `check` found a difference |
| Built with | Zig 0.16.0, standard library only |

---

## Settings
| Key | What | Default |
|---|---|---|
| `pick.dirs` | folder names whose files are picked | `[".secrets"]` |
| `pick.files` | file patterns picked anywhere (`*` = any run) | `*token.json`, `*client_secret.json`, `*credentials.json` |
| `pick.skip_dirs` | folder names never entered | `.git`, `zig-out`, `.zig-cache`, `node_modules`, `zzzz-delete-force-items` |
| `pick.skip_markers` | a folder holding one of these files is a browser profile and is skipped | `Local State`, `Preferences` |
| `pick.skip` | path patterns to leave out | none |
| `pick.file_maxz_kbyt` | biggest file picked (KB) | 256 |
| `pick.total_maxz_mbyt` | biggest bundle (MB); more is refused | 64 |
| `bundle.path` | the bundle file, relative to `--repo` | `05-cloud-house/secret-bundle.enc` |
| `bundle.pass_envz` | env variable that may hold the passphrase | `SECRET_BUNDLE_PASS` |
| `bundle.pass_min` | shortest passphrase for `pack` | 16 |
| `argon.time` / `argon.memo_kbyt` / `argon.para` | lock cost | 3 / 65536 / 1 |
| `unpack.file_mode` | mode of restored files (owner only) | `600` |
| `unpack.trash` | where a replaced local file is saved (`{home}` = your home) | `{home}/.05-cloud-house-secre/bundle-trash` |

---

## Files
| What | Where |
|---|---|
| The bundle | `<repo>/<bundle.path>` (commit it) |
| Old local copies | `unpack.trash/<yyMMdd_HHmmss>/<path>` (outside the repo, never committed) |
| Passphrase | nowhere: typed each time, or from the env variable for one command |
