# How To

Every option, with steps. See `05-README.md` first for the quick start.
Steps marked **(untested on a real account)** need your Oracle account. Everything else was run against a practice copy of Oracle.

`EXE` below means `/home/mai_trang/05-cloud-house/10-vend-apps/oracle/zig-out/rel/x86_64-linux-musl/bin/oracle-setup` (Windows: `...\oracle-setup.exe`).
Run the commands from the folder that holds `00-config.json`:
```
cd /home/mai_trang/05-cloud-house/10-vend-apps/oracle
```

---

## 1. Check the program runs
```
EXE version
```
You should see: `oracle-setup 0.1.0`
Not working? Make sure the file exists at the path above.

## 2. See the plan
```
EXE plan
```
You should see the 12 steps, then:
```
hand jobs: 3 total, 0 done · steps left: 12
```
This changes nothing.

## 3. Set your vault passphrase
The vault locks the keys the program makes. Pick 8 or more characters and keep it.
Linux or Mac:
```
export CLOUD_HOUSE_VAULT_PASS='pick-a-long-phrase'
```
Windows (PowerShell):
```
$env:CLOUD_HOUSE_VAULT_PASS = 'pick-a-long-phrase'
```
Skip this and the program asks you each time.

## 4. Practice run
```
EXE run
```
You should see: `dry-run: nothing was called and nothing was written. Add --live to run for real.`

## 5. Run for real **(untested on a real account)**
```
EXE run --live
```
The program goes step by step and stops when it needs you. Do each hand job, then come back.

**Hand job 1: sign up.** A page opens. Fill name, email, country. Add a card (a hold, not a charge). Click the link in Oracle's email. Type `g` and press Enter.

**Hand job 2: home region.** Type the region id you chose at sign-up, for example `eu-frankfurt-1`, and press Enter. You cannot change it later. Free computers only live there.

**Step 3 is automatic:** the program makes your signing key and locks it in the vault.

**Hand job 3: log in and add the key.** A page opens (and the key text is on your clipboard).
1. Log in. Approve the phone check if Oracle asks.
2. Profile > API keys > Add API key > Paste a public key.
3. Paste the text from your clipboard. Click Add.
4. Oracle shows a preview. Copy its lines and paste them into the terminal, one line each: `user=...`, `fingerprint=...`, `tenancy=...`, `region=...`. Press Enter after each.

The program then checks the key works. After that it needs nothing from you.

You should end with a report like:
```
free quota: VMs 1/2 (50%), boot disk 50/200 GB (25%)
VM: cloud-house-vm  ip: <address>
```
Not working? → see "When something goes wrong".

## 6. Log in to your new computer **(untested on a real account)**
```
EXE sshkey /home/mai_trang/vm-login-key
ssh -i /home/mai_trang/vm-login-key ubuntu@<address>
```
`sshkey` never overwrites an existing file. Use a new file name each time.

## 7. Run it again any time
```
EXE run --live
```
Finished steps are skipped. Nothing is created twice.

## 8. Check nothing changed
```
EXE drift
```
`drift: none` means all good. Exit code 3 means a firewall door you did not set, or the computer is not running. The program never removes anything; look in the Oracle console.

## 9. Put your own program on the computer
Do this before the first `run --live`. Open `00-config.json` and set `boot.urlz` (where to download your program) and `boot.sha2` (its sha256 fingerprint). The default VM is Arm, so also set `boot.urla` and `boot.sh2a` for the Arm build of your program. The computer reads them once, on its first start. Changing them later does not touch a computer that already exists.

## 10. Stop using the keys
```
EXE revoke
```
This removes the keys from the vault. It cannot touch Oracle. To remove the API key there: Profile > API keys > the key with the fingerprint shown > Delete.

---

## When something goes wrong
| Message | What to do |
|---|---|
| `unknown or missing command` | Use one of: plan, run, status, drift, revoke, sshkey, vault, version, help |
| `config error: ... line N` | Fix that line in `00-config.json` and run again |
| `no vault passphrase` | Set `CLOUD_HOUSE_VAULT_PASS` (step 3) |
| `vault error: VaulPass` | Wrong passphrase. Retype it |
| `openssl not found` | Install openssl, or set `keyz.file` to an existing key file |
| `Oracle still refuses the key` | The key was added to the wrong user, or your PC clock is off by 5+ minutes. Fix and rerun |
| `no free VM capacity right now` | Oracle has none free in your region. Rerun later; it resumes at that step |
| `shape ... is not Always Free` | You changed `inst.shap` to a paid type. Revert, or set `paid.okay` and use `--paid` knowing it costs money |
| `quota: 2 of 2 free VMs already exist` | You already use the free allowance. Nothing more is created |
| `that fingerprint is not ours` | You pasted the preview of a different key. Paste the one you just added |
