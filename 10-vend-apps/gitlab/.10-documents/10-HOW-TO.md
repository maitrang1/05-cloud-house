# How To

Every task, step by step. See `05-README.md` first. Run the commands from the app folder:
```
cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/gitlab
```

---

## Set it up (first time)
1. Make sure the GitHub app has run and `gh auth status` says you are logged in.
2. Choose how you log in to GitLab:
   - **With `glab`:** install it, then run `glab auth login --hostname gitlab.com --device` once and approve the code in your browser.
   - **With your own OAuth app:** on GitLab open your profile, Applications, add a new application (scope `api`, not confidential), copy its Application ID, and put it in the private file `~/.05-cloud-house-secre/gitlab-account.json` as `{"clid": "the-id"}`.
3. Check the plan, nothing changes:
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/gitlab/zig-out/bin/gitlab-setup run
```
4. Run it for real:
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/gitlab/zig-out/bin/gitlab-setup run --go
```
5. When it asks you to sign up or confirm an email, do it in the browser. Press the key it names, and run the same command again.

---

## See where it stands
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/gitlab/zig-out/bin/gitlab-setup status
```

---

## Check the mirror
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/gitlab/zig-out/bin/gitlab-setup drift
```

---

## Renew the push token
It renews itself 14 days before it expires. To do it now:
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/gitlab/zig-out/bin/gitlab-setup rotate
```

---

## Undo what the app made
Kills the mirror token. Your project stays.
```
/home/mai_trang/00_modules/05-cloud-house/10-vend-apps/gitlab/zig-out/bin/gitlab-setup revoke
```

---

## If something goes wrong
| You see | Do this |
|---|---|
| `NoClientId` | You have neither `glab` nor an OAuth app id. Do one of the two in "Set it up" step 2 |
| `GlabMissing` | `glab` is not installed. Install it, or use an OAuth app id |
| `UsernameTaken` | That name is taken on GitLab. Put another name in `~/.05-cloud-house-secre/gitlab-account.json` as `{"user": "name"}` |
| `no GitHub login` | Run `gh auth login` first |
| Mirror upload refused | The GitHub app must write its private ssh config first (it does so on every publish) and the GitLab key file must exist |
