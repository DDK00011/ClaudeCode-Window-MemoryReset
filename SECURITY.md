# Security Policy

## Security characteristics

MemoryReset is a **high-privilege tool** that performs the following operations:

- automatic elevation with administrator privileges (UAC)
- force-kill arbitrary processes (`taskkill /F /T`)
- working set manipulation of all processes (`EmptyWorkingSet`)
- kernel memory list manipulation (`NtSetSystemInformation`)
- enable `SeProfileSingleProcessPrivilege`
- direct System File Cache trimming

Be sure to review the **source code (especially the `Get-TargetProcesses` function)** before using the script.
If you cannot trust the distribution, compare the SHA256 hash of GitHub releases with the hash of the directly downloaded file.

## Supported versions

| Version | Supported |
|---------|-----------|
| 1.0.x | ✅ |
| < 1.0 | ❌ |

## Reporting a vulnerability

Please report privately through one of the following channels:

1. **GitHub Security Advisories** (recommended) — repository Security tab → Report a vulnerability
2. Do not report through GitHub Issue (public exposure may enable exploitation)

### Response time

- Acknowledgment: within 5 business days
- Share fix/mitigation timeline: within 14 days

### Please include in your report

- Affected versions
- Reproduction steps
- Scope of impact / threat scenario
- (If possible) proposed fix

## Known risks

| Risk | Mitigation |
|------|-----------|
| Claude Desktop app may terminate incorrectly | multi-path blacklist + pre-check with `Run-DryRun.bat` |
| Terminating itself (script PID) | explicit exclusion of `$PID` |
| Automatic restart after termination (Antigravity auto recovery) | Handle by simply restarting. For permanent blocking, use Antigravity settings |
| Terminating processes of other users (with administrator privileges) | This script can enumerate only current user processes. On multi-user systems, adding an SID filter to `Get-TargetProcesses` is recommended |

## Disclaimer

This tool is provided "AS IS" under the MIT License. The user is responsible for data loss, system instability, and lost work resulting from use. Always verify in a test environment before use in production.
