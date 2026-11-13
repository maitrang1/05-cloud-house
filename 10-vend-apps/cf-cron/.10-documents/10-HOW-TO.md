# How To

Every option, with steps. See `05-README.md` first for the quick start.
Steps marked **(not tested on a real account)** need your Cloudflare account. Everything else was run against a practice Cloudflare on this machine.

---

## Set it up
**Step 1 · Pick a passphrase**
It protects your vault. Use 8 or more characters and keep it somewhere safe.
Linux:
```
export CLOUD_HOUSE_VAULT_PASS="your long passphrase"
```
Windows (CMD):
```
set CLOUD_HOUSE_VAULT_PASS=your long passphrase
```
If you skip this, the app asks you to type it, hidden.

**Step 2 · Set your Trigger address**
Open `/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cf-cron/00-config.json`. Under `trig`, set `url` to your Trigger address, with no path, for example `https://cloud-house-trigger.onrender.com`. The Worker will call `url` + `path` (`/tick`).

**Step 3 · Preview**
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cf-cron/zig-out/bin/cf-cron-setup run
```
You should see `dry-run: nothing is changed` and `hand jobs: 2`.
Not working? → `trig.url is EMPTY` means step 2 is not done.

**Step 4 (optional) · Add a tick secret**
If your Trigger checks a secret header, store the secret once. The Worker then sends it as `x-tick-secret`.
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cf-cron/zig-out/bin/cf-cron-setup secret trigger.tick_secret
```
Type or paste the value (hidden). Skip this if your Trigger needs no secret.

---

## Run it for real **(not tested on a real account)**
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cf-cron/zig-out/bin/cf-cron-setup run --go
```
**Hand job 1 · Sign up.** The app opens the Cloudflare sign-up page. Sign up, click the link in the email, and when you see your dashboard type `g` and press Enter. Already have an account? Log in and type `g`.

**Hand job 2 · Make one API token.** The app opens the API Tokens page. Click **Create Token**, then **Create Custom Token**. Add two permissions: **Account · Workers Scripts · Edit** and **Account · Account Settings · Read**. Create it, copy it, go back to the window, paste it (you will not see it) and press Enter.
You should see `done: token vaulted and accepted`.
Not working? → `the token was refused`: make a new token with both permissions and run again.

The rest runs alone. A new cron can take up to 15 minutes to start ticking.

---

## Change something later
Changed `cron.peri` or `trig.url` or the tick secret? Apply it:
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cf-cron/zig-out/bin/cf-cron-setup sync --go
```
The Worker is uploaded again only if something in it changed.

## Check it now
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cf-cron/zig-out/bin/cf-cron-setup check
```
Shows whether the Worker answers and which cron is live.

## Switch it off
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cf-cron/zig-out/bin/cf-cron-setup revoke --go
```
Turns the cron off (the Worker stays) and forgets your token. Then delete the token in the dashboard (My Profile > API Tokens). Switch on again with `run --go` and a fresh token.

---

## Practice without an account
This is how the app was tested. Nothing real is touched.

**Step 1 · Start the practice Cloudflare**
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cf-cron/zig-out/bin/cf-cron-mock 0
```
It prints `mock listening <port>`. Keep it open.

**Step 2 · Point a copy of the config at it**
Copy `00-config.json`. In the copy set: `cfla.apiz` to `http://127.0.0.1:<port>/client/v4`, `cfla.rout` to `http://127.0.0.1:<port>/w/{scri}`, `trig.url` to `http://127.0.0.1:<port>`. In the practice, the token is `cfut_FAKETOKEN_0123456789abcdefghij`.

**Step 3 · Run**
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cf-cron/zig-out/bin/cf-cron-setup run --go --conf <your copy>
```
Type `g`, then paste the fake token. You should end with `done: 10  skipped: 0  to-do: 0  hand jobs used: 2`. Run it again: nothing changes.
