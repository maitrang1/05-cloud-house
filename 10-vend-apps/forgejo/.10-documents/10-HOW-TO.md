# How To

Every command, step by step. See `05-README.md` first. Commands run on your Linux server. Windows can run `status` and `vault` only.

---

## Set it up (first time)
1. Create your Linux server first (the only manual job).
2. Copy `forgejo-setup` and `00-config.json` to the server, in the same folder.
3. Create the private file `~/.05-cloud-house-secre/forgejo-account.json` with your admin name and email: `{"user": "your-name", "mail": "you@example.com"}`. Keep it out of `00-config.json`, which is copied to the public repo.
4. Check the plan, nothing changes:
```
forgejo-setup run
```
It prints what it would do.
5. Run it for real (as root). Type a vault passphrase when asked, or set `CLOUD_HOUSE_VAULT_PASS` first:
```
forgejo-setup run --go
```
6. Each step shows `done:` or `skipped:`. The end shows `hand jobs used: 0`.

If it stops, run the same command again. It picks up where it left off.

---

## See what was made
```
forgejo-setup status
```
Shows the admin name, repo, token name and push address.

---

## Check your two code homes match
```
forgejo-setup drift
```
`drift: heads match` is good. Exit code 3 means the two copies differ: push again from your computer.

---

## Cut off the app's access
```
forgejo-setup revoke
```
Deletes only the token this app made and removes it from the vault.

---

## Upgrade Forgejo
1. Set a new `rele.vers` in `00-config.json`.
2. Move the old file `/usr/local/bin/forgejo` away by hand (the app never deletes).
3. Run `forgejo-setup run --go` again.

---

## Not tested on a real server yet
Every step above was tested on a pretend server. The first real run should be on a scratch server.

---

## When something goes wrong
| Message | What to do |
|---|---|
| `config error: ... rele.vers must name a release` | Set `rele.vers` in `00-config.json` |
| `config error: set admi.user and admi.mail` | Fill both in `forgejo-account.json` (data folder) |
| `failed: NeedLinux` | Run it on the Linux server |
| `failed: SumMismatch` | The download is not genuine. Nothing was installed. Try again later |
| `failed: BinaDiffers` | A different file is already at `host.bina`. Move it away by hand, run again |
| `failed: TokenMintFail` | The token name exists but the vault lost it. Run `revoke`, then `run --go` |
| `failed: BootTime` | Forgejo did not start. Check `systemctl status forgejo` |
| `failed: RepoNotPrivate` | The repo was made public by hand. Make it private in Forgejo, run again |
| `failed: NoPassphrase` | Set `CLOUD_HOUSE_VAULT_PASS` or run in a terminal |
| `failed: Unauthorized` | The token is wrong or revoked. Run `revoke`, then `run --go` |
