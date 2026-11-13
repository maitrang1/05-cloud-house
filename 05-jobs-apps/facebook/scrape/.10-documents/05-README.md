# Facebook Scrape

Reads Facebook data for you and hands it back as clean rows: public Pages, posts, comments and Marketplace listings, plus your own Page's inbox, comments, leads, live videos and statistics.
No login to anyone's account. It only reads. It cannot post, reply or message.

---

## What it does
You list the Facebook addresses you care about. The tool reads them through scraping services, logged out, and keeps one row per fact. Run it again and nothing is added twice. For your own Page you connect once with Facebook's own approval screen, and the tool reads the Page through Facebook's official interface. Each customer's data stays separate.

---

## Requirements
- Linux (x86_64) or Windows (x86_64)
- Nothing else to install
- Keys for the parts you use (a Meta app for your own Page, a scraping service for public data). `10-HOW-TO.md` shows where to get each

---

## Quick Start
1. Make a secret key and pick a data folder:
```
export SCRAPE_MASTER_KEY=$(openssl rand -hex 32)
export SCRAPE_HOME=/home/you/facebook-data
```
2. Add a customer and one public Page to read:
```
/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/facebook/scrape/zig-out/bin/scrape cust --cust acme --add-target page=https://www.facebook.com/example
```
You see:
```
acme: 1 target(s) · webhook none · vendors on · consent NO
```
3. Record that the customer agrees, then preview:
```
/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/facebook/scrape/zig-out/bin/scrape consent --cust acme --grant
/home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/facebook/scrape/zig-out/bin/scrape scan --cust acme --dry-run
```
You see:
```
  ok       page https://www.facebook.com/example
scan acme (dry-run): fetched 0 · added 0 · dup 0 · skipped 0 · blocked 0 · failed 0 · refused 0 · no vendor 0 · over cap 0 · credits 0
```
The preview sends nothing. To read for real, set a scraping service key first (`10-HOW-TO.md`, step "Read public Pages").

---

## Where Output Goes
Rows go to `SCRAPE_HOME/cust/<customer>/rows.jsonl`. Each customer has its own folder. Nothing else is shared.

---

## Next
- **`10-HOW-TO.md`** — every command, with steps
- **`15-CONFIG.md`** — every setting and file
- **`20-UPDATE.md`** — what changed, by date

---

## License
PolyForm Noncommercial 1.0.0. Free for personal and noncommercial use (hobby, study, research, charity). Using it in a business or for profit needs a paid commercial license: open an issue at https://github.com/maitrang1/05-cloud-house/issues. Full text: `25-LICENSE`.
