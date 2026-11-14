# Zalo Chat Scrape

Reads public Zalo pages and your own Zalo data, and keeps clean, no-duplicate rows for you.
No window, no website: you run it from the command line. Your data stays in one folder on your computer.

---

## What it does
You give it Zalo page addresses, or connect your own Zalo Official Account. It collects what is public (name, text, picture link) and, for your own account, your followers, chats and articles. Each customer's data is kept apart from every other customer's. Run it twice and nothing is stored twice. It only reads. It never sends a message.

---

## Requirements
- Linux or Windows, 64-bit
- Nothing to install. (Only the optional personal-account reader needs Node 20 or newer.)

---

## Quick Start
1. Add a customer and a Zalo page:
```
/home/mai_trang/05-cloud-house/05-jobs-apps/zalochat/scrape/zig-out/linux-x86_64/bin/scrape cust --cust acme --add-url https://zalo.me/cuahangmau
```
```
acme: 1 url(s) · webhook none · vendors on · consent NO
```
2. Record that the customer agrees to their data being stored:
```
/home/mai_trang/05-cloud-house/05-jobs-apps/zalochat/scrape/zig-out/linux-x86_64/bin/scrape consent --cust acme --grant
```
```
acme: consent granted
```
3. Check the address is allowed (no page is fetched yet):
```
/home/mai_trang/05-cloud-house/05-jobs-apps/zalochat/scrape/zig-out/linux-x86_64/bin/scrape scan --cust acme --dry-run
```
```
  ok       https://zalo.me/cuahangmau
scan acme (dry-run): fetched 0 · added 0 · dup 0 · 404 0 · robots 0 · blocked 0 · failed 0 · refused 0 · over cap 0
```
4. Collect it for real: run the same command without `--dry-run`.

On Windows use `E:\00_modules\05-cloud-house\05-jobs-apps\zalochat\scrape\zig-out\windows-x86_64\bin\scrape.exe` instead.

---

## Where Your Data Goes
Everything is kept in one folder (your home folder, in `.zalochat-scrape`). Each customer gets their own sub-folder. Set the `SCRAPE_HOME` variable to use another place. Nothing leaves your computer unless you set up delivery to your own web address.

---

## Next
- **`10-HOW-TO.md`**: every task, step by step
- **`15-CONFIG.md`**: every setting and where things go
- **`20-UPDATE.md`**: what changed, by date

---

## License
PolyForm Noncommercial 1.0.0. Free for personal and noncommercial use (hobby, study, research, charity). Using it in a business or for profit needs a paid commercial license: open an issue at https://github.com/maitrang1/05-cloud-house/issues. Full text: `25-LICENSE`.
