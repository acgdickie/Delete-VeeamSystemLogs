# Veeam System Log Cleanup
PowerShell script to clean up Veeam Backup &amp; Replication system log folders (Retention, CheckpointRemoval) that have no built-in auto-rotation. Designed to run standalone or via RMM tools like NinjaOne, Datto, or ConnectWise.

## Target Directories
The script cleans up subfolders within:
- `C:\ProgramData\Veeam\Backup\System\CheckpointRemoval`
- `C:\ProgramData\Veeam\Backup\System\Retention`

## Features
- **Safe by Default**: Defaults to `DryRun = $true`. It will only report what it *would* do unless explicitly told to perform the deletion.
- **RMM Optimized**: Parameters are handled as strings to maintain compatibility with RMM tools that do not pass native PowerShell Booleans.
- **Error Resilience**: If a folder's size cannot be calculated (e.g., due to file locks or permissions), the script skips that folder and flags an error rather than performing a partial or unsafe deletion.
- **Detailed Logging**: Provides per-folder age and size reporting in the console output.

## Configuration
- **Retention Period**: Hardcoded to **90 days**. Subfolders with a `LastWriteTime` older than this are candidates for deletion.
- **Execution Account**: Designed to run as `SYSTEM` (standard for RMM agents).

## Usage

### Via RMM Tool
Set the script to run on a schedule. To enable actual deletion, pass the following parameter:
- **Parameter Name**: `DryRun`
- **Value**: `false` (or `0`, `no`, `n`)

### Manual Execution
To test the script and see what would be deleted:
```powershell
.\Delete-VeeamSystemLogs.ps1 -DryRun true
```

To perform the actual cleanup:
```powershell
.\Delete-VeeamSystemLogs.ps1 -DryRun false
```

## Exit Codes
| Code | Meaning |
| :--- | :--- |
| 0 | Success. Cleanup completed (or no files needed cleaning). |
| 1 | Error. This occurs if parameter conversion fails, a target directory is inaccessible, or a deletion attempt failed. |

## Safety Logic
1. **Discovery**: The script identifies top-level subfolders in the target paths older than 90 days.
2. **Verification**: It attempts to recursively calculate the size of each folder.
3. **Validation**: If any file inside that folder is inaccessible, the folder is skipped to ensure operator confidence.
4. **Action**: Only if `DryRun` is explicitly `false` will the `Remove-Item -Recurse -Force` command be executed.

---
**Author:** Richard Bradley  
**Version:** 1.2
