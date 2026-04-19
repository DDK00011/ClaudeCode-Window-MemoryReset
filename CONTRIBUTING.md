# Contributing to MemoryReset

Contributions are welcome. This document is a guide to follow when submitting PR/issues.

## Compatibility requirements

**MUST**:
- PowerShell **5.1** compatible (Windows 10/11 default PS, must work without additional installation)
- UTF-8 **BOM** preservation (so messages are not mistaken for ANSI)
- C# (P/Invoke) sections must be compatible with .NET Framework 4.x

**SHOULD**:
- Ensure it works with PowerShell 7+ too (but syntax exclusive to PS 7 is prohibited)
- ASCII-only identifiers (variable/function names)
- Write comments in English

## Change verification

### 1. Parse verification
```powershell
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    '.\MemoryReset.ps1', [ref]$null, [ref]$errors)
if ($errors.Count) { $errors | Format-List }
```

### 2. Pattern regression verification
Must run when changing the process identification logic (`Get-TargetProcesses`):
```powershell
.\Test-Patterns.ps1
```
- Preserve Claude Desktop: verify `[PASS]`
- Exclude own PID: verify `[PASS]`
- When adding a new category, also synchronize the classification logic in Test-Patterns.ps1

### 3. Dry run
Verify behavior without actually terminating:
```cmd
Run-DryRun.bat
```

### 4. Verify UTF-8 BOM
```powershell
$bytes = [System.IO.File]::ReadAllBytes('.\MemoryReset.ps1')
if ($bytes[0..2] -join ',' -ne '239,187,191') { 'BOM missing' }
```

## Commit messages

Conventional Commits recommended:
```
feat: <one-line feature addition summary>

Detailed description...

Closes #123
```

Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`

## PR checklist

- [ ] 0 parse errors
- [ ] `Test-Patterns.ps1` PASS (if applicable)
- [ ] Measured verification with `Run-DryRun.bat`
- [ ] Add an entry to the `[Unreleased]` section of CHANGELOG.md
- [ ] Cite authoritative sources (MSDN/phnt headers) when adding new P/Invoke
- [ ] Keep user-facing messages consistent (when adding/changing user output)

## Style guide

- Indentation: 4 spaces (tabs prohibited)
- Line length: 120 characters or less recommended
- Function names: `Verb-Noun` PowerShell convention (`Get-`, `Set-`, `Invoke-`, `Stop-` etc.)
- Variable names: `$camelCase`
- Constants: `$UPPER_SNAKE` or `public const` on the C# side

## Risky changes

The following changes require additional review:

1. `Get-TargetProcesses` whitelist/blacklist — incorrect matches can cause user data loss
2. Changing `taskkill` arguments — removing `/T` can miss helper processes
3. Changing P/Invoke signatures — marshaling errors can corrupt memory
4. Changing UAC elevation logic — risk of permission bypass

For a PR, identifying risky parts + attaching regression verification results is recommended.
