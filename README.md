# ScriptLibrary

Reusable Office-IT engineering scripts, one folder per system. Documentation for these
scripts lives in the Office-IT BookStack - the pages below are the authoritative
instructions, this repository holds the code.

- Source Control (OITCLOUD repo sync):
  https://docs.office-it.net/books/source-control/page/sync-all-oitcloud-repositories-to-a-workstation
- Veeam pipeline - source control and deployment:
  https://docs.office-it.net/books/veeam/page/veeam-pipeline-source-control-and-deployment

## Contents

| Folder | Contents |
| --- | --- |
| `Cloudflare/` | Cloudflare tooling (as-built documentation generator) |
| `GitHub/` | OITCLOUD repository sync: token setup, sync, scheduled task, access diagnostic |
| `NinjaOne/` | NinjaOne endpoint scripts |

## Conventions

- PowerShell targets **Windows PowerShell 5.1** unless a script states otherwise in its
  header block.
- `.ps1` files are **pure ASCII, no BOM**. A non-ASCII character in a BOM-less .ps1 is read
  as Windows-1252 by PS 5.1 and produces cascading parse errors that point at the wrong
  line. Verify before committing:

  ```powershell
  $p = '.\Your-Script.ps1'
  $e = $null; [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$e) | Out-Null
  Write-Output ("Parse errors: {0} (expected 0)" -f $e.Count)
  $bad = ([System.IO.File]::ReadAllBytes($p) | Where-Object { $_ -gt 127 }).Count
  Write-Output ("Non-ASCII bytes: {0} (expected 0)" -f $bad)
  ```

- Every script carries a header block (`.SYNOPSIS`, `.DESCRIPTION`, `.NOTES`) and a
  verification step with the expected result stated.
- No credentials, tokens or tenant IDs as literals.
