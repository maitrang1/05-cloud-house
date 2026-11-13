# How To

Every task, with steps. See `05-README.md` first for the quick start.
Each command below starts with the program's full path. On Windows, use the `.exe` path from the README.

---

## Collect public Zalo pages
1. Add the pages (only `https://zalo.me/...` style addresses are accepted):
```
/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/zalochat/scrape/zig-out/linux-x86_64/bin/scrape cust --cust acme --add-url https://zalo.me/cuahangmau
```
2. Run it:
```
/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/zalochat/scrape/zig-out/linux-x86_64/bin/scrape scan --cust acme
```
It waits a few seconds between pages, reads each site's robots rules first, and stops at once if a site blocks it. Running it again changes nothing unless a page changed.

## Look at what was stored
```
/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/zalochat/scrape/zig-out/linux-x86_64/bin/scrape rows --cust acme --since 0
```
Each line is one row. The last line says `next cursor: N`. Use `--since N` next time to get only new rows.

## Check a customer
```
/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/zalochat/scrape/zig-out/linux-x86_64/bin/scrape state --cust acme
```
```
cust acme: rows 0 · fetches today 0 · month runs 0 pages 0 credits 0 · delivered to cursor 0
```

## Connect a customer's Zalo Official Account
Needs your Zalo app's ID and secret, a master key, and the redirect address set in the settings.
1. Set the keys once (keep them private):
```
export SCRAPE_MASTER_KEY=$(openssl rand -hex 32)
export ZALO_APP_ID=your-app-id
export ZALO_APP_SECRET=your-app-secret
```
2. Get the consent link and open it in a browser:
```
/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/zalochat/scrape/zig-out/linux-x86_64/bin/scrape login --cust acme --tier oa
```
3. Allow access. Copy the code from the address bar, then connect:
```
/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/zalochat/scrape/zig-out/linux-x86_64/bin/scrape login --cust acme --tier oa --code PASTE-THE-CODE
```
4. Pull followers, chats and the message quota (needs the customer's consent):
```
/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/zalochat/scrape/zig-out/linux-x86_64/bin/scrape sync --cust acme --tier oa
```
5. Pull your articles and videos list: use `--tier articles`. Import Mini App numbers from a file you exported yourself: use `--tier mini --file /full/path/export.csv`.

## Get rows sent to your web address
1. Set the address and a shared secret:
```
/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/zalochat/scrape/zig-out/linux-x86_64/bin/scrape cust --cust acme --webhook https://example.com/hook
export SCRAPE_HOOK_SECRET=a-long-random-secret
```
2. Send the next batch:
```
/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/zalochat/scrape/zig-out/linux-x86_64/bin/scrape rows --cust acme --push
```
Each batch is signed. Your server should check the signature and the time before trusting it. A batch that fails is retried, then parked, and sent again next time.

## Turn off the paid-helper fallback for one customer
```
/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/zalochat/scrape/zig-out/linux-x86_64/bin/scrape cust --cust acme --vendors off
```
Helpers are only used when a page answers "forbidden", errors, or times out. Never for a "slow down" answer or a CAPTCHA.

## Test a helper service
```
export ZENROWS_KEY=your-key
/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/zalochat/scrape/zig-out/linux-x86_64/bin/scrape probe zenrows https://zalo.me/cuahangmau --dry-run
```
```
GET https://api.zenrows.com/v1/?apikey=%2A%2A%2A&url=https%3A%2F%2Fzalo.me%2Fcuahangmau
```
The key is hidden. Remove `--dry-run` to make one real call. `--revive` switches a helper back on after its key was rejected.

## Turn on channel and video pages (optional)
They stay off until a helper service reads 20 sample pages cleanly. Run the proof with 20 or more addresses:
```
/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/zalochat/scrape/zig-out/linux-x86_64/bin/scrape chan proof --vendor zenrows --url https://zalo.me/a --url https://zalo.me/b
```
If it passes, `scrape chan scan --cust acme --url ...` works. If not, it says `FAIL - stays OFF`. Only links and details are kept, never the video files.

## Export a customer's data
```
/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/zalochat/scrape/zig-out/linux-x86_64/bin/scrape dump --cust acme --out /home/mai_trang/exports/acme
```
```
acme: dump /home/mai_trang/exports/acme - 0 rows, 0 files, verify OK. Secrets are never exported.
```

## Remove a customer completely
1. See what would go (nothing is removed):
```
/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/zalochat/scrape/zig-out/linux-x86_64/bin/scrape purge --cust acme
```
2. Export first (above), then remove for good:
```
/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/zalochat/scrape/zig-out/linux-x86_64/bin/scrape purge --cust acme --yes
```
Add `--old` instead of `--yes` to drop only private chat rows older than the keep-time.

## Stop everything fast
Create an empty file named `KILL` in the data folder. Every run refuses to start until you remove it. A customer that fails three runs in a row is paused by itself: fix the cause, then run `scrape state --cust acme --resume`.

## Use a personal Zalo account (optional, risky)
Off by default. It is unofficial and can get an account locked. Use a spare account only.
1. Set `side.enabled` to `true` in the settings, install Node 20 or newer, and install the reader's parts once:
```
cd /home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/zalochat/scrape/side && npm ci --ignore-scripts --omit=dev
```
2. Log in and scan the picture with the spare account:
```
/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/zalochat/scrape/zig-out/linux-x86_64/bin/scrape login --cust acme --tier personal
```
3. Read friends, groups you are in, and group history (no phone numbers are kept):
```
/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/zalochat/scrape/zig-out/linux-x86_64/bin/scrape sync --cust acme --tier personal
```
4. See the safety state. One lock or dead session cuts the tier for that account:
```
/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/zalochat/scrape/zig-out/linux-x86_64/bin/scrape risk --cust acme
```
```
acme: drilling · clean days 0/7 · events 0
```

---

## When something goes wrong
| Message | What to do |
|---|---|
| `error: config: UnknownField at line 1 col 6` | A setting name is misspelled. Fix that line in the settings file. |
| `error: url refused (NotAllowed)` | Only the allowed Zalo hosts work. Use `https://zalo.me/NAME`. |
| `error: master key missing or bad` | Set `SCRAPE_MASTER_KEY` to 64 hex characters, once, and keep it safe. |
| `error: no consent on file` | Run `consent --grant` after the customer agrees. |
| `error: kill switch is on` | Remove the `KILL` file, or set `sche.kill_switch` to false. |
| `error: cust ... is paused` | Fix the cause, then `state --cust ID --resume`. |
| `error: OA token is dead` | Run `login --tier oa` again with the customer. |
| `error: another host holds the lease` | Only one computer may read a personal account at a time. Wait or stop the other one. |
| `error: personal tier stopped` | Zalo ended or limited the session. The tier is cut. Check `risk`, and log in again only on purpose. |
