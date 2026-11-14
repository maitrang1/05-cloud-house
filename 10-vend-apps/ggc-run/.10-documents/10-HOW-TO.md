# How To

Every option, with steps. See `05-README.md` first for the quick start.
Tested on 2026-11-13 against a pretend Google on this PC (real Google: not yet tried). Steps that need your Google account are marked **not tested live**.

`EXE` below means:
- Linux/macOS: `/home/mai_trang/05-cloud-house/10-vend-apps/ggc-run/zig-out/bin/ggc-run`
- Windows: `E:\00_modules\05-cloud-house\10-vend-apps\ggc-run\zig-out\rel\x86_64-windows\bin\ggc-run.exe`

---

## Set up Cloud Run (first time)

**Step 1 · Install `gcloud`** (once, **not tested live**)
Open https://cloud.google.com/sdk/docs/install and follow the page for your computer. Open a new terminal, then:
```
gcloud --version
```
You should see a line starting with `Google Cloud SDK`. Not working? Close the terminal and open a new one.

**Step 2 · Read the plan** (nothing changes)
```
EXE run
```
You should see 12 lines like `03 [todo] auto Create the project`, then `dry-run: nothing was changed. Pass --go to run for real.`

**Step 3 · Run it for real**
```
EXE run --go
```
It stops at three places where only you can act:
1. **Google account.** A page opens. Sign in or create a normal personal account. Type `g` here. (Skipped if you are already logged in.)
2. **Login code.** `gcloud` shows a link. Open it, approve, paste the code back in the terminal.
3. **Billing card.** A page opens. Add your card and start the billing account. The tool notices by itself (a few seconds). If it does not, type `g`.

Keys while it waits: `g` done · `h` hint · `b` try again · `x` stop (run the command again later; it continues where it stopped).

**Step 4 · Read the end**
```
== report ==
done: 10  skipped: 2  to-do: 0  hand jobs used: 1
```
(`hand jobs used` is 3 on a brand-new setup; the sample above is from the pretend run, where one of the three was needed.) The service address is printed as `url:`.

---

## Run it again
Safe any time. Steps already done are skipped. If you change a setting (for example the image), run `EXE run --go` again and it updates only what differs.

## Look at the plan or the state
```
EXE plan
EXE status
```
`plan` lists the steps and which are done. `status` shows the project, billing account, service account, image and address the tool learned.

## Check the free quota
```
EXE usage
```
You should see lines like `requests: 0 of 2000000 (0.0%)`. At 80% a line ends with `WARNING` and the command exits with code 3. Google's numbers lag a few minutes.

## Use your own program image
1. Put your image on GitHub's registry and make it public (the tool never stores a password).
2. In `00-config.json` set `imag.sour` to `owner/image:tag` (for example `maitrang1/cloud-job:latest`).
3. Run `EXE run --go`. It makes a pull-through repo and points the service at it.

## Take back public access
```
EXE revoke
EXE revoke --go
```
The first only says what would happen. The second removes public access to the service and logs out the `gcloud` login this tool made. It deletes nothing.

## Try it with no Google account (pretend Google)
1. Start the pretend Google (leave this window open):
```
/home/mai_trang/05-cloud-house/10-vend-apps/ggc-run/zig-out/bin/ggc-run-mock --bill-after 2
```
It prints `mock port 43425` (your number will differ) and `token ya29.mock-token`.
2. Copy `00-config.json` to a new file. In the copy set every address under `apis` to `http://127.0.0.1:<port>/crm`, `/bill`, `/budg`, `/usag`, `/iam`, `/arti`, `/run`, `/moni`, set `auth.mode` to `env`, and `goog.proj_iden` to `cloud-house-guide01`.
3. In a second window set the token and use a throw-away home folder, then run:
```
HOME=/tmp/ggc-try GGC_RUN_TOKEN=ya29.mock-token EXE run --go --conf /tmp/ggc-try/conf.json
```

---

## When something goes wrong
| Message | What to do |
|---|---|
| `gcloud not found` | Install `gcloud` (Step 1), open a new terminal, run again. |
| `Google refused the token` | Log in again: `gcloud auth login --no-launch-browser`, then run again. |
| `more than one open billing account` | Open `00-config.json`, set `budg.bill_acct` to the one to charge, run again. |
| `project not created` | The account may not be allowed to create projects. Ask the Google admin, or set `goog.proj_iden` to a project you own. |
| `could not allow public calls` | Your organisation forbids public services. Ask the admin, or set `serv.publ` to `false`. |
| `service is not Ready` | Open Cloud Run logs for the service, fix the image, run again. |
| `remote repo has another upstream` | Set `goog.arty` to a new name, run again. |
| `config error: ... line N col M` | A setting is misspelled or out of range; fix that line. |
| `still not detected after you confirmed` | The page step is not finished yet. Finish it, run again. |
