#Requires -Version 5.1

<#

.SYNOPSIS

    Deletes folders older than 90 days from selected Veeam system log directories.

.DESCRIPTION

    Designed to run as an RMM tool scheduled script (runs as SYSTEM).

    Targets:
    - C:\ProgramData\Veeam\Backup\System\CheckpointRemoval
    - C:\ProgramData\Veeam\Backup\System\Retention

    The script is intentionally conservative:
    - It defaults to Dry Run mode so first deployment or manual testing cannot
      accidentally remove data.
    - It logs every folder that would be deleted or was deleted.
    - It treats discovery/enumeration failures as operational failures so
      the RMM tool receives a non-zero exit code when SYSTEM could not fully inspect
      the cleanup target.
    - It skips deleting a folder if the script cannot fully enumerate that
      folder while calculating its size. This avoids deleting something after
      only partially inspecting it.

.PARAMETER DryRun

    Controls whether folders are actually removed.

    Default: true

    Supported values:
    - true, 1, yes, y
    - false, 0, no, n

    The RMM tool passes parameters and script variables as strings, not native
    PowerShell Boolean values. For that reason this parameter is declared as a
    string and converted explicitly inside the script.

    Manual examples:

        .\Delete-VeeamSystemLogs.ps1
        .\Delete-VeeamSystemLogs.ps1 -DryRun true
        .\Delete-VeeamSystemLogs.ps1 -DryRun false

    RMM tool examples:
    - Parameters field: false
    - Script variable: create a variable named DryRun with value false

.NOTES

    Author:  Richard Bradley

    Version: 1.2

    Exit codes:
    - 0 = Completed without cleanup errors; missing target paths are skipped.
    - 1 = Invalid parameter value, folder discovery failed, folder size
          enumeration failed, or one or more deletions failed.

#>

# The RMM tool's Automation Parameters and Script Variables arrive as strings.
# Keeping this as [string] avoids PowerShell parameter binding surprises when
# the RMM tool sends "false" instead of a native Boolean $false.
param(
    [string]$DryRun = ''
)

<#
.SYNOPSIS
    Converts a string-style automation parameter into a Boolean.

.DESCRIPTION
    The RMM tool cannot reliably pass native Boolean values to custom PowerShell
    scripts. It sends values as strings, so this helper accepts common
    human-friendly true/false spellings and returns a real [bool].

    Empty or whitespace-only values are treated as "not supplied" and resolve to
    the caller-provided default. For this script, that default is $true so Dry
    Run remains the safe behavior unless explicitly disabled.

    Invalid values are considered configuration errors. The function throws so
    the caller can log a clean message and exit with code 1, ensuring the RMM tool
    marks the run as failed instead of silently proceeding with an ambiguous mode.

.PARAMETER Name
    Friendly parameter name used in the error message.

.PARAMETER Value
    Raw string value supplied on the command line or through NinjaOne.

.PARAMETER Default
    Boolean value to use when Value is blank or missing.
#>
function ConvertTo-BoolParameter {
    param(
        [string]$Name,
        [string]$Value,
        [bool]$Default
    )

    # Blank means "the caller did not choose a mode". Returning the default lets
    # the script remain safe-by-default without forcing RMM tool users to set a
    # variable for every scheduled run.
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Default
    }

    # Accept a small set of obvious truthy/falsy strings so the script is easy
    # to run manually and easy to configure in the RMM tool's string-only fields.
    switch -Regex ($Value.Trim()) {
        '^(?i:true|1|yes|y)$'  { return $true }
        '^(?i:false|0|no|n)$'  { return $false }
        default {
            # Throw rather than exit so the caller controls the exit path.
            # This keeps the function portable if dot-sourced by a parent script.
            throw "[ERROR] Invalid $Name value '$Value'. Use true or false."
        }
    }
}



# ── Configuration ──────────────────────────────────────────────────────────────

$TargetPaths = @(
    "C:\ProgramData\Veeam\Backup\System\CheckpointRemoval",
    "C:\ProgramData\Veeam\Backup\System\Retention"
)
$MaxAgeDays = 90

# Convert the raw string input to a real Boolean once, then use the normalized
# value for all later decisions and log output.
try {
    $DryRun = ConvertTo-BoolParameter -Name 'DryRun' -Value $DryRun -Default $true
} catch {
    Write-Output $_.Exception.Message
    exit 1
}

# ───────────────────────────────────────────────────────────────────────────────



# The reference date is captured once at startup so all folders in this run are judged
# against the same timestamp.
$Now              = Get-Date
$CutoffDate       = $Now.AddDays(-$MaxAgeDays)

# These counters feed the summary and final process exit code. The RMM tool treats a
# non-zero exit code as a failed automation, so every operational problem that
# matters must increment $ErrorCount.
$DeletedCount     = 0
$WouldDeleteCount = 0
$ErrorCount       = 0
$TotalSize        = 0



Write-Output "=============================================="
Write-Output "Veeam System Log Cleanup Script"
Write-Output "=============================================="
Write-Output "Target Paths :"
foreach ($TargetPath in $TargetPaths) {
    Write-Output "             - $TargetPath"
}
Write-Output "Max Age      : $MaxAgeDays days"
Write-Output "Cutoff Date  : $($CutoffDate.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Output "Dry Run      : $DryRun"
Write-Output "Run Time     : $($Now.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Output "----------------------------------------------"



# ── Process target paths ──────────────────────────────────────────────────────

foreach ($TargetPath in $TargetPaths) {
    Write-Output ""
    Write-Output "Target Path  : $TargetPath"
    Write-Output "----------------------------------------------"

    # Missing target paths are not treated as failures. Some endpoints may not
    # have both Veeam system log folders yet, and the other target should still
    # be inspected and cleaned in the same run.
    if (-not (Test-Path -LiteralPath $TargetPath -PathType Container)) {
        Write-Output "WARNING: Target path does not exist. Nothing to clean up for this path."
        continue
    }

    # Capture discovery errors instead of discarding them. We still use
    # SilentlyContinue to keep PowerShell from writing noisy non-terminating
    # errors directly into the output stream, but ErrorVariable lets us log clean
    # messages and fail the script at the end.
    $DiscoveryErrors = @()
    $OldFolders = Get-ChildItem -LiteralPath $TargetPath -Directory -Force -ErrorAction SilentlyContinue -ErrorVariable DiscoveryErrors |
        # Only top-level folders are candidates. This cleanup intentionally does
        # not inspect child item ages when deciding eligibility; the operational
        # policy is based on the age of the Veeam system log child folder itself.
        Where-Object { $_.LastWriteTime -lt $CutoffDate }

    # If SYSTEM cannot enumerate the target directory completely, the cleanup
    # result is not trustworthy. Log every discovery error and count it so
    # the RMM tool receives exit code 1 even if there are no folders to delete.
    if ($DiscoveryErrors.Count -gt 0) {
        foreach ($DiscoveryError in $DiscoveryErrors) {
            Write-Output "[ERROR] Failed to enumerate target path: $($DiscoveryError.Exception.Message)"
        }
        $ErrorCount += $DiscoveryErrors.Count
    }

    if ($OldFolders.Count -eq 0) {
        Write-Output "No folders older than $MaxAgeDays days found. Nothing to delete for this path."
        continue
    }

    Write-Output "Found $($OldFolders.Count) folder(s) older than $MaxAgeDays days."
    Write-Output ""

    foreach ($Folder in $OldFolders) {

        # Age is calculated from LastWriteTime to match the eligibility decision
        # above. It is logged for operator review in the RMM tool output.
        $FolderAge = ($Now - $Folder.LastWriteTime).Days

        # Size calculation requires a recursive walk. Access-denied or path
        # errors here mean the script did not fully inspect the folder, so the
        # folder is skipped and the run is marked as failed.
        $SizeErrors = @()
        $FolderSize = (Get-ChildItem -LiteralPath $Folder.FullName -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable SizeErrors |
            # Measure-Object sums file lengths. Directories do not have Length,
            # so they do not contribute to the result. If there are no files,
            # Sum can be null and is normalized to zero below.
            Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum

        # Do not delete if folder enumeration was incomplete. This is
        # deliberately stricter than "best effort" cleanup because a partial
        # view can hide files that should affect operator confidence.
        if ($SizeErrors.Count -gt 0) {
            foreach ($SizeError in $SizeErrors) {
                Write-Output "[ERROR]   $($Folder.Name) | Failed to enumerate folder contents: $($SizeError.Exception.Message)"
            }
            $ErrorCount += $SizeErrors.Count
            # Continue to the next candidate folder. Other folders can still be
            # logged or deleted, but the final exit code will be 1 because at
            # least one folder could not be inspected.
            Write-Output "[SKIPPED] $($Folder.Name) | Age: ${FolderAge} days | Folder enumeration failed"
            continue
        }

        # Empty folders produce a null Sum. Treat them as 0 MB so logging and
        # numeric addition remain consistent.
        if ($null -eq $FolderSize) {
            $FolderSize = 0
        }

        $FolderSizeMB = [math]::Round(($FolderSize / 1MB), 2)
        $FolderLabel = Join-Path -Path (Split-Path -Path $TargetPath -Leaf) -ChildPath $Folder.Name

        if ($DryRun) {
            # Dry Run is the default and is intended for testing policy scope in
            # the RMM tool. It logs exactly what would be removed without touching
            # disk.
            Write-Output "[DRY RUN] $FolderLabel | Age: ${FolderAge} days | Size: ${FolderSizeMB} MB"
            $WouldDeleteCount++
            $TotalSize += $FolderSize
        } else {
            try {
                # Actual deletion only happens when DryRun resolves to $false.
                # Remove-Item is wrapped in try/catch with ErrorAction Stop so
                # access or filesystem failures become catchable terminating
                # errors.
                Remove-Item -LiteralPath $Folder.FullName -Recurse -Force -ErrorAction Stop
                Write-Output "[DELETED] $FolderLabel | Age: ${FolderAge} days | Size: ${FolderSizeMB} MB"
                # Only count space after a successful deletion. Failed deletions
                # are counted separately and leave TotalSize unchanged.
                $DeletedCount++
                $TotalSize += $FolderSize
            } catch {
                # Deletion failures must be visible to the RMM tool. Counting them
                # here ensures a partial cleanup exits with code 1.
                Write-Output "[ERROR]   $FolderLabel | $($_.Exception.Message)"
                $ErrorCount++
            }
        }
    }
}



# ── Summary ────────────────────────────────────────────────────────────────────

# Summary output is intentionally simple text because the RMM tool captures stdout
# and displays it in automation history. Keep labels stable for easy scanning.
$TotalSizeMB = [math]::Round(($TotalSize / 1MB), 2)

Write-Output ""
Write-Output "=============================================="
Write-Output "Summary"
Write-Output "=============================================="

if ($DryRun) {
    # In Dry Run mode, no deletion is attempted. Counts and sizes reflect only
    # folders that were successfully enumerated and are eligible for removal.
    # Skipped folders (enumeration errors) are excluded from both counts.
    Write-Output "Mode         : DRY RUN (no folders were deleted)"
    Write-Output "Would Delete : $WouldDeleteCount folder(s)"
    Write-Output "Would Free   : ${TotalSizeMB} MB"
    Write-Output "Errors       : $ErrorCount"
} else {
    # In live mode, Deleted and Errors together show whether the run was clean,
    # partial, or failed. Space Freed reflects successful deletions only.
    Write-Output "Deleted      : $DeletedCount folder(s)"
    Write-Output "Errors       : $ErrorCount"
    Write-Output "Space Freed  : ${TotalSizeMB} MB"
}

Write-Output "=============================================="



# ── Exit code for NinjaOne ─────────────────────────────────────────────────────

# The RMM tool uses the process exit code to determine automation success/failure.
# Any counted error means the cleanup was incomplete or misconfigured, so return
# 1. A clean run returns 0.
if ($ErrorCount -gt 0) {
    exit 1
}

exit 0
