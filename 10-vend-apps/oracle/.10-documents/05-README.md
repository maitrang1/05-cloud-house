# Oracle Cloud Free VM Setup

One program that sets up a free Linux computer in Oracle Cloud for you, and keeps it that way.
It needs no install, no account on our side, and never deletes anything.

---

## What it does
Oracle gives every new account a small always-on Linux computer for free. Setting it up by hand takes many clicks. This program does everything except the three things only you can do: sign up with a card, pick your home region, and log in to add one key. After that it makes the network, the firewall, the computer, and prints how to log in. Run it twice and nothing changes.

---

## Requirements
- Windows 10 or later, or Linux (x86_64)
- A card for Oracle sign-up (Oracle holds a small amount to check you are real)
- `openssl` on your PC to make the key (Linux has it; Windows users can point to a key file instead)
- Nothing else. No install.

---

## Quick Start
1. See the plan (nothing happens):
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/oracle/zig-out/rel/x86_64-linux-musl/bin/oracle-setup plan
```
You will see 12 steps and `hand jobs: 3 total, 0 done · steps left: 12`.
2. Set a passphrase for the key vault (8+ characters):
```
export CLOUD_HOUSE_VAULT_PASS='pick-a-long-phrase'
```
3. Run it for real and follow the prompts:
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/oracle/zig-out/rel/x86_64-linux-musl/bin/oracle-setup run --live
```

---

## Where Output Goes
Everything lives in one folder, `~/.05-cloud-house-secre`: the locked vault, a progress file, a call log with secrets hidden, and a backup of your settings. The last step prints your computer's address and the login command.

---

## Next
- **`10-HOW-TO.md`**: every step, one tiny action at a time
- **`15-CONFIG.md`**: every setting
- **`20-UPDATE.md`**: what changed, by date
