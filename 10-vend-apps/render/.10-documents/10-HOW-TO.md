# How To

Every option, with steps. See `05-README.md` first for the quick start.
Steps marked **(not tested on a real account)** need your Render account. Everything else was run against a practice Render on this machine.

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

**Step 2 · Set your image**
Open `/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/render/00-config.json`. Under `rend`, set `imag` to your public image, for example `ghcr.io/you/cloud-house-trigger:latest`. The image must be public and listen on the port Render gives it.

**Step 3 · Preview**
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/render/zig-out/bin/render-setup run
```
You should see `dry-run: nothing is changed` and `hand jobs: 2`.
Not working? → `rend.imag is EMPTY` means step 2 is not done.

---

## Run it for real **(not tested on a real account)**
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/render/zig-out/bin/render-setup run --go
```
**Hand job 1 · Sign up.** The app opens the Render page. Click the GitHub button. When you see your dashboard, type `g` and press Enter. Already have an account? Log in and type `g`.

**Hand job 2 · Make one API key.** The app opens Account Settings. Click **Create API Key**, copy it, go back to the window, paste it (you will not see it) and press Enter.
You should see `done: key vaulted and accepted`.
Not working? → `the key was refused`: make a new key and run again.

The rest runs alone. A new service takes a few minutes to start, so the cold-start check may wait. It ends with a report.

---

## Practice without an account
This is how the app was tested. Nothing real is touched.

**Step 1 · Start the practice Render**
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/render/zig-out/bin/render-mock 0 1
```
It prints `mock listening <port>`. Keep it open.

**Step 2 · Point a copy of the config at it**
Copy `00-config.json` and set `rend.apiz` to `http://127.0.0.1:<port>/v1`. Set `rend.imag` to any text, for example `ghcr.io/fake/x:1`. In the practice, the key is `rnd_FAKEKEY`.

**Step 3 · Run**
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/render/zig-out/bin/render-setup run --go --conf /path/to/your-copy.json
```
Type `g`, then paste `rnd_FAKEKEY`. You get the same report as a real run.

---

## Run it again
Run the same `run --go` command. Steps already done are skipped, nothing is created twice, and no hand job repeats.
```
== report ==
done: 0  skipped: 1  to-do: 0  hand jobs used: 0
```

## Check on it
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/render/zig-out/bin/render-setup status
```
Shows the service address and each step's mark.

## Time a cold start
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/render/zig-out/bin/render-setup cold
```
Prints `cold start: answered in 1s (202 window 60s)`. A free service sleeps after 15 idle minutes, so run it after a quiet spell to see a true cold start.

## Send new environment values
Put the value in the vault under the name set in `envs` (see `15-CONFIG.md`), then run `run --go` again. It sends the list and starts one deploy, only when something changed.

## Stop using it
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/render/zig-out/bin/render-setup revoke --go
```
It pauses the service and removes the key from the vault. Then delete the key in Render under Account Settings > API Keys (Render gives no way to do that from a program). To resume the service, use the dashboard.

---

## When something goes wrong
| Message | What to do |
|---|---|
| `config error: ConfJson line N` | A typo in `00-config.json` at that line. Fix it. |
| `paid plan needs guar.paid true and guar.capz above 0` | You set a paid plan. Set it back to `free`, or opt in on purpose. |
| `rend.imag is empty` | Set your public image path in the config. |
| `the key was refused` | Make a new key in Account Settings and run again. |
| `plan is starter but config says free` | Someone changed the plan in the dashboard. The app never changes plans. Fix it there or in the config. |
| `the service is suspended` | Resume it in the dashboard, or run `revoke` only when you mean it. |
| `env var X is needed but vault key Y is empty` | Put the value in the vault, run again. |
| `too many calls` | Wait a minute and run again. It resumes. |
| `no 200 within 600s` | The first deploy is slow or failed. Check the dashboard, then run `cold`. |
| `wrong vault passphrase` | Use the passphrase you first set. |
