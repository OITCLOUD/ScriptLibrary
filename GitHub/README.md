# OITCLOUD Repo Sync

Keeps a local copy of every non-archived repository in the **OITCLOUD** GitHub organization
up to date on a Windows workstation, unattended, from a scheduled task. Safe by design: it
clones what is missing and fast-forwards what is clean, and never touches a working copy
that has local changes.

**Full work instruction in the Office-IT BookStack:**
https://docs.office-it.net/books/source-control/page/sync-all-oitcloud-repositories-to-a-workstation

**Related:**
https://docs.office-it.net/books/veeam/page/veeam-pipeline-source-control-and-deployment

Read the BookStack page first if you are setting this up on a new machine - it covers the
GitHub token permissions, which is where every failure so far has come from.

---

## Files

| File | Purpose | Run as |
| --- | --- | --- |
| `Set-OitcloudSyncToken.ps1` | One-time: validates a GitHub PAT and stores it DPAPI-encrypted. | Interactive, as the account the task will run as |
| `Sync-OitcloudRepos.ps1` | The sync itself. Safe to run by hand or scheduled. | That same account |
| `Register-OitcloudSyncTask.ps1` | Creates/removes the scheduled task. | Elevated PowerShell |
| `Test-OitcloudSyncAccess.ps1` | Read-only diagnostic: per-repo token access and local writability. | That same account |

Windows PowerShell 5.1, pure ASCII, no BOM. All four parse with 0 errors.

## Prerequisites

- Membership of the OITCLOUD organization.
- Git for Windows on `PATH`.
- A fine-grained PAT, resource owner OITCLOUD, **All repositories**, **Contents: Read-only**
  (Metadata comes along automatically), approved by an org owner.

> A token with only Metadata lists every repository through the API but cannot read a byte
> with git. Private repos then fail with `remote: Write access to repository not granted.`
> and a 403 - a misleading message for a missing **read** permission. Public repos keep
> working, so the failure looks random.

## Install

```powershell
.\Set-OitcloudSyncToken.ps1
# Expected: "PASS: token file verified OK: ...\oitcloud-token.sec"

.\Sync-OitcloudRepos.ps1 -WhatIf     # dry run, writes nothing
.\Sync-OitcloudRepos.ps1
# Expected last line: "RESULT: PASS (<n> repositories processed, 0 failures)"

.\Register-OitcloudSyncTask.ps1 -At 07:30 -RepeatEveryHours 4   # elevated
# Expected: task registered, State Ready, LogonType Password
```

Default repo root is `C:\GITWork`. Override with `-RepoRoot` on both the sync and the
register script.

`-RepeatEveryHours 4` creates six daily triggers (07:30, 11:30, 15:30, 19:30, 23:30, 03:30)
rather than a repetition interval: a repetition duration of `[TimeSpan]::MaxValue`
serialises to `P99999999DT23H59M59S`, which Task Scheduler rejects outright.

## What happens per repository

| Situation | Action | Reported |
| --- | --- | --- |
| Not cloned yet | `git clone` default branch | `CLONED` |
| Clean, behind origin | `git fetch --prune` + `git merge --ff-only` | `UPDATED` |
| Clean, up to date | fetch only | `CURRENT` |
| Clean, ahead of origin | fetch only - unpushed commits | `AHEAD` |
| Uncommitted changes | fetch only, working tree untouched | `SKIP-DIRTY` |
| Diverged / detached / no upstream | fetch only | `SKIP-*` |
| Folder exists but is not a git repo | nothing | `SKIP-NOTAREPO` |
| Local folder no longer in the org | nothing, never deleted | `ORPHAN` |

No `reset`, `checkout`, `clean`, `stash` or `rebase`, and no merge other than `--ff-only`.
There is no code path that can discard local work.

Limits: syncs the currently checked-out branch only, and does not run
`git submodule update`.

## Token handling

- DPAPI (`ConvertFrom-SecureString`): decryptable only by that Windows user on that machine.
- Written `-Encoding ASCII -NoNewline`, read back through a BOM-stripping helper and proven
  to decrypt before setup reports success. (`Set-Content -Encoding UTF8` in 5.1 writes a BOM
  that makes `ConvertTo-SecureString` fail with "Input string was not in a correct format".)
- File ACL reduced to that single account.
- Git receives the token through a per-run `GIT_ASKPASS` shim and a process-scoped
  environment variable. It never reaches `.git/config`, a remote URL or a command line, and
  the configured credential helper is disabled per invocation so nothing is cached.

## Why the task stores a Windows password

Registered with `LogonType Password`, not S4U. "Run whether user is logged on or not"
without a stored password runs S4U, which does not load the user's DPAPI master key, so the
token cannot be decrypted and every run fails at startup.

## Token expiry

Each run reads the `GitHub-Authentication-Token-Expiration` header and logs
`Token expiry : 2027-09-11 (360 days left)`. Inside 30 days this becomes a warning repeated
at the bottom of the summary. Renewing the PAT changes its value, so
`Set-OitcloudSyncToken.ps1` must be re-run; editing an existing token's permissions does not.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Completed, 0 failures (skips are normal and listed in the summary) |
| 1 | Fatal: git missing, token unreadable, API unreachable, no repos in scope |
| 2 | Completed, but one or more repositories failed - read the log |
| 0x41303 | Task never ran: account lacks "Log on as a batch job" (secpol.msc) |

Logs: `%LOCALAPPDATA%\Office-IT\GitHubSync\logs\sync-<timestamp>.log`, newest 30 kept.

## Verification

```powershell
Get-ScheduledTask -TaskName 'Sync-OITCLOUD-Repos' -TaskPath '\Office-IT\' |
    Select-Object TaskName, State, @{n='User';e={$_.Principal.UserId}}, @{n='Logon';e={$_.Principal.LogonType}}
# Expected: State = Ready, Logon = Password

$hits = Get-ChildItem C:\GITWork -Recurse -Depth 2 -Filter config -File -Force |
    Select-String -Pattern 'ghp_|github_pat_|x-access-token:' -List
if ($hits) { Write-Output "FAIL: token material found in:"; $hits.Path }
else { Write-Output "PASS: no token material in any .git/config" }
```
