# How To

Every command, with steps. See `05-README.md` first for the quick start. In every command below, `scrape` means:
`/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/facebook/scrape/zig-out/bin/scrape` (Windows: `...\zig-out\bin-windows\scrape.exe`).

---

## Set up once
1. Make the secret key that seals Page tokens. Keep it safe; lose it and you must reconnect.
```
export SCRAPE_MASTER_KEY=$(openssl rand -hex 32)
```
2. Pick where data lives:
```
export SCRAPE_HOME=/home/you/facebook-data
```
3. Check it runs:
```
scrape state
```
You see `facebook-scrape 0.1.0`, your data folder, and the job names.

---

## Add a customer and targets
```
scrape cust --cust acme --add-target page=https://www.facebook.com/example
```
Kinds: `page`, `post`, `cmnt`, `item`, `adlib`. A non-Facebook address is refused:
`error: url refused (NotAllowed)`. Other options: `--webhook https://your.site/hook`, `--vendors off`, `--daily-cap 50`, `--retention-days 90`.

## Record consent
Names, messages and comments are personal data. Without consent nothing is read.
```
scrape consent --cust acme --grant
```
`--revoke` stops everything for that customer. To remove their data, see "Remove a customer".

---

## Read public Pages
1. Sign up at a scraping service and copy its key. Set a spend limit on the service's site.
2. Put the key in the variable named in `df-scrape-vendors.json` (for example `SCRAPECREATORS_KEY`):
```
export SCRAPECREATORS_KEY=<YOUR_KEY>
```
3. Test the key with one call:
```
scrape probe scrapecreators https://www.facebook.com/example
```
Without a key you see `error: no key`. `--dry-run` shows the request with the key hidden.
4. Preview, then read:
```
scrape scan --cust acme --dry-run
scrape scan --cust acme
```
A reply looks like `scan acme: fetched 1 · added 1 · dup 0 ...`. Run it again: `added 0`. If every vendor is off or has no key: `no vendor 1` and exit code 2.

The tool stops for good on a CAPTCHA or checkpoint page (exit code 3). It never tries to solve one.

---

## Connect your own Page
Hand steps (once). Do one, then the next:
1. At developers.facebook.com create an app, add **Facebook Login**, copy the app id and secret:
```
export FACE_APP_ID=<YOUR_APP_ID>
export FACE_APP_SECRET=<YOUR_APP_SECRET>
```
2. In `00-config.json` set `graph.redirect_uri` to your https callback address.
3. Get the consent link:
```
scrape login --cust acme
```
4. Open the link, log in as a Page admin, tick every Page, approve. Copy the `code=` value from the address you land on.
5. Connect:
```
scrape login --cust acme --code <CODE>
```
You see `acme: connected Page <id> (<name>)`. Check it any time with `scrape login --cust acme --status`. A dead token shows `DEAD (reconnect)` and exit code 3: run steps 3–5 again.

Until Meta approves your app (App Review and Business Verification), it can read only Pages where you hold a role on the app. Start both early.

## Read your Page
```
scrape sync --cust acme
```
Or only some parts: `--only inbox,wall,lead,lives,stats`. Run it again: nothing is added twice. The tool slows down at 80% of Meta's limit and stops at 95%.

---

## Receive Facebook webhooks
Your web host passes Facebook's request to the tool. Each part is one command:
- Handshake: `scrape hook verify --mode subscribe --token <VERIFY_TOKEN> --challenge <NUMBER>` prints the number back. A wrong token: `error: handshake refused`, exit 3.
- Events: save the raw request body to a file, then `scrape hook event --file /path/body.json --sig 'sha256=<HEX>'`. A forged signature: `error: bad signature`, exit 3.
- Deletion: `scrape hook delete --signed-request <VALUE>` prints `{"url":...,"confirmation_code":...}` for Facebook. Check later with `scrape hook status --code <CODE>` (`done` or `unknown`).

In the Meta app form set the callback, the verify token (`FACE_HOOK_VERIFY`), the Page fields you want, and the Data Deletion URL. Subscribe each Page to your app in its settings.

---

## Get your rows
- Pull: `scrape rows --cust acme --since 0 --limit 100` (the last line gives the next cursor).
- Push to the customer's webhook: `scrape rows --cust acme --push` (signed, retried, then parked).

## Export and remove
```
scrape dump --cust acme
scrape purge --cust acme
scrape purge --cust acme --yes
```
`dump` writes a copy without secrets and checks it. The plain `purge` is a preview. `--yes` removes the customer for good. `scrape purge --cust acme --old` only removes rows past their expiry.

---

## When something goes wrong
| Message | What to do |
|---|---|
| `error: no consent for acme` | `scrape consent --cust acme --grant` |
| `error: url refused (NotAllowed)` | Use a facebook.com address |
| `error: no key` | Set the key variable named in the message |
| `no vendor 1` (exit 2) | No vendor is on, or no key is set. Check `df-scrape-vendors.json` and the key |
| `error: no redirect address` | Set `graph.redirect_uri` in `00-config.json` |
| `error: master key missing or bad` | `export SCRAPE_MASTER_KEY=$(openssl rand -hex 32)` |
| `error: Facebook refused the code` | The code is used or old. Run `scrape login --cust acme` again |
| `error: that Page belongs to another cust` | One Page, one customer. Purge the other one first |
| `error: handshake refused` | The verify token differs from `FACE_HOOK_VERIFY` |
| `error: kill switch is on` | Turn off `sche.kill_switch` or remove the `KILL` file |
| `error: cust acme is paused` | Fix the cause, then `scrape state --cust acme --resume` |
| Exit code 3 on `scan` | A vendor hit a CAPTCHA. Wait; try another vendor |
| Exit code 3 on `sync` | Dead token, or Meta limit reached. Reconnect, or wait |
