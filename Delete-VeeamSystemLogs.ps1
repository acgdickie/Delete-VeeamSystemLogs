#Requires -Version 5.1

<#

.SYNOPSIS

    Deletes folders and files older than a specified retention period from Veeam log directories.

.DESCRIPTION

    Designed to run as an RMM tool scheduled script (runs as SYSTEM).

    Folder targets (deletes subfolders older than MaxAgeDays):
    - C:\ProgramData\Veeam\Backup\System\CheckpointRemoval
    - C:\ProgramData\Veeam\Backup\System\Retention

    These can be overridden by the FolderTargetPaths parameter.

    File targets (deletes files older than MaxAgeDays):
    - C:\ProgramData\Veeam\Backup\Export_logs
    - C:\ProgramData\Veeam\Backup\ExplorerStandByService\Logs

    These can be overridden by the FileTargetPaths parameter.

    The script is intentionally conservative:
    - It defaults to Dry Run mode so first deployment or manual testing cannot
      accidentally remove data.
    - It logs every folder or file that would be deleted or was deleted.
    - It treats discovery/enumeration failures as operational failures so
      the RMM tool receives a non-zero exit code when SYSTEM could not fully inspect
      the cleanup target.
    - It skips deleting a folder if the script cannot fully enumerate that
      folder while calculating its size. This avoids deleting something after
      only partially inspecting it.

.PARAMETER DryRun

    Controls whether folders and files are actually removed.

    Default: true

    Supported values:
    - true, 1, yes, y
    - false, 0, no, n

    The RMM tool passes parameters and script variables as strings, not native
    PowerShell Boolean values. For that reason this parameter is declared as a
    string and converted explicitly inside the script.

.PARAMETER FolderTargetPaths

    A comma-separated string of folder paths to clean up. Subfolders within
    these paths older than MaxAgeDays will be deleted.
    Defaults to the Veeam system log folders if not specified.

.PARAMETER FileTargetPaths

    A comma-separated string of file paths to clean up. Files directly within
    these paths older than MaxAgeDays will be deleted.
    Defaults to the Veeam system log file paths if not specified.

.PARAMETER MaxAgeDays

    The maximum age in days for items to be retained. Items older than this
    threshold are candidates for removal.
    Default: 90

.EXAMPLE
    .\Delete-VeeamSystemLogs.ps1 -DryRun false -MaxAgeDays 30

.EXAMPLE
    .\Delete-VeeamSystemLogs.ps1 -FolderTargetPaths "C:\Temp\Logs" -DryRun true

.NOTES

    Author:  Richard Bradley

    Version: 1.4

    Exit codes:
    - 0 = Completed without cleanup errors; missing target paths are skipped.
    - 1 = Invalid parameter value, discovery failed, item size enumeration
          failed, or one or more deletions failed.

#>

# The RMM tool's Automation Parameters and Script Variables arrive as strings.
# Keeping this as [string] avoids PowerShell parameter binding surprises when
# the RMM tool sends "false" instead of a native Boolean $false.
param(
    [string]$DryRun = '',
    [string]$MaxAgeDays = '',
    [string]$FolderTargetPaths = '',
    [string]$FileTargetPaths = ''
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
    Raw string value supplied on the command line or through the RMM tool.

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



# ── Helper Function: Process-CleanupTarget ─────────────────────────────────────

<#
.SYNOPSIS
    Processes a single target path for cleanup, either folders or files.

.DESCRIPTION
    Encapsulates the logic for identifying and removing items based on age.
    Handles folder size calculation and provides detailed logging.

.PARAMETER TargetPath
    The root directory to inspect.
.PARAMETER TargetType
    Whether to look for 'Folder' sub-directories or 'File' items.
.PARAMETER CutoffDate
    The calculated timestamp used to determine eligibility.
.PARAMETER DryRunEnabled
    When true, items are logged but not deleted.
.PARAMETER Now
    The current timestamp used for age reporting.
.PARAMETER DeletedCount, WouldDeleteCount, ErrorCount, TotalSize
    Reference variables used to update global script counters.
#>
function Process-CleanupTarget {
    param(
        [Parameter(Mandatory=$true)]
        [string]$TargetPath,
        [Parameter(Mandatory=$true)]
        [ValidateSet('Folder', 'File')]
        [string]$TargetType,
        [Parameter(Mandatory=$true)]
        [datetime]$CutoffDate,
        [Parameter(Mandatory=$true)]
        [bool]$DryRunEnabled,
        [Parameter(Mandatory=$true)]
        [datetime]$Now,
        [Parameter(Mandatory=$true)]
        [ref]$DeletedCount,
        [Parameter(Mandatory=$true)]
        [ref]$WouldDeleteCount,
        [Parameter(Mandatory=$true)]
        [ref]$ErrorCount,
        [Parameter(Mandatory=$true)]
        [ref]$TotalSize
    )

    Write-Output ""
    Write-Output "Target Path  : $TargetPath"
    Write-Output "Target Type  : $TargetType"
    Write-Output "----------------------------------------------"

    if (-not (Test-Path -LiteralPath $TargetPath -PathType Container)) {
        Write-Output "WARNING: Target path does not exist. Nothing to clean up for this path."
        return
    }

    $DiscoveryErrors = @()
    $ItemsToProcess = @()

    if ($TargetType -eq 'Folder') {
        $ItemsToProcess = Get-ChildItem -LiteralPath $TargetPath -Directory -Force -ErrorAction SilentlyContinue -ErrorVariable DiscoveryErrors |
            Where-Object { $_.LastWriteTime -lt $CutoffDate }
    } else {
        $ItemsToProcess = Get-ChildItem -LiteralPath $TargetPath -File -Force -ErrorAction SilentlyContinue -ErrorVariable DiscoveryErrors |
            Where-Object { $_.LastWriteTime -lt $CutoffDate }
    }

    if ($DiscoveryErrors.Count -gt 0) {
        foreach ($DiscoveryError in $DiscoveryErrors) {
            Write-Output "[ERROR] Failed to enumerate target path: $($DiscoveryError.Exception.Message)"
        }
        $ErrorCount.Value += $DiscoveryErrors.Count
    }

    if ($ItemsToProcess.Count -eq 0) {
        Write-Output "No $($TargetType.ToLower())s found older than the cutoff. Nothing to delete."
        return
    }

    foreach ($Item in $ItemsToProcess) {
        $ItemAge = ($Now - $Item.LastWriteTime).Days
        $ItemSize = 0
        $ItemLabel = Join-Path -Path (Split-Path -Path $TargetPath -Leaf) -ChildPath $Item.Name

        if ($TargetType -eq 'Folder') {
            $SizeErrors = @()
            $ItemSize = (Get-ChildItem -LiteralPath $Item.FullName -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable SizeErrors |
                Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
            if ($SizeErrors.Count -gt 0) {
                Write-Output "[ERROR]   $($Item.Name) | Failed to enumerate contents: $($SizeErrors[0].Exception.Message)"
                $ErrorCount.Value += $SizeErrors.Count
                continue
            }
        } else {
            $ItemSize = $Item.Length
        }

        $ItemSize = $ItemSize -replace '^$', 0
        $ItemSizeMB = [math]::Round(($ItemSize / 1MB), 2)

        if ($DryRunEnabled) {
            Write-Output "[DRY RUN] $ItemLabel | Age: ${ItemAge} days | Size: ${ItemSizeMB} MB"
            $WouldDeleteCount.Value++
            $TotalSize.Value += $ItemSize
        } else {
            try {
                Remove-Item -LiteralPath $Item.FullName -Recurse:$($TargetType -eq 'Folder') -Force -ErrorAction Stop
                Write-Output "[DELETED] $ItemLabel | Age: ${ItemAge} days | Size: ${ItemSizeMB} MB"
                $DeletedCount.Value++
                $TotalSize.Value += $ItemSize
            } catch {
                Write-Output "[ERROR]   $ItemLabel | $($_.Exception.Message)"
                $ErrorCount.Value++
            }
        }
    }
}


# ── Configuration ──────────────────────────────────────────────────────────────

# Handle FolderTargetPaths parameter or environment variable
if ([string]::IsNullOrWhiteSpace($FolderTargetPaths) -and -not [string]::IsNullOrWhiteSpace($env:FolderTargetPaths)) {
    $FolderTargetPaths = $env:FolderTargetPaths
}
if ([string]::IsNullOrWhiteSpace($FolderTargetPaths)) {
    $ConfiguredFolderTargetPaths = @(
        "C:\ProgramData\Veeam\Backup\System\CheckpointRemoval",
        "C:\ProgramData\Veeam\Backup\System\Retention"
    )
} else {
    $ConfiguredFolderTargetPaths = $FolderTargetPaths.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim() }
}

# Handle FileTargetPaths parameter or environment variable
if ([string]::IsNullOrWhiteSpace($FileTargetPaths) -and -not [string]::IsNullOrWhiteSpace($env:FileTargetPaths)) {
    $FileTargetPaths = $env:FileTargetPaths
}
if ([string]::IsNullOrWhiteSpace($FileTargetPaths)) {
    $ConfiguredFileTargetPaths = @(
        "C:\ProgramData\Veeam\Backup\Export_logs",
        "C:\ProgramData\Veeam\Backup\ExplorerStandByService\Logs"
    )
} else {
    $ConfiguredFileTargetPaths = $FileTargetPaths.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim() }
}

# Handle MaxAgeDays parameter or environment variable
if ([string]::IsNullOrWhiteSpace($MaxAgeDays) -and -not [string]::IsNullOrWhiteSpace($env:MaxAgeDays)) {
    $MaxAgeDays = $env:MaxAgeDays
}
try {
    if ([string]::IsNullOrWhiteSpace($MaxAgeDays)) {
        $MaxAgeDays = 90
    } else {
        $MaxAgeDays = [int]$MaxAgeDays
    }
} catch {
    Write-Output "[ERROR] Invalid MaxAgeDays value '$MaxAgeDays'. Please provide a number."
    exit 1
}

# The RMM tool exposes script variables to PowerShell as environment variables.
# If the command-line parameter was not supplied, allow a script variable named
# "DryRun" to control the mode. Command-line input wins when both are present.
if ([string]::IsNullOrWhiteSpace($DryRun) -and -not [string]::IsNullOrWhiteSpace($env:DryRun)) {
    $DryRun = $env:DryRun
}

# Convert the raw string input to a real Boolean once, then use the normalized
# value for all later decisions and log output. Keep it in a separate variable
# because the [string] parameter would convert Boolean $false back to "False",
# and non-empty strings are truthy in PowerShell conditionals.
try {
    $DryRunEnabled = ConvertTo-BoolParameter -Name 'DryRun' -Value $DryRun -Default $true
} catch {
    Write-Output $_.Exception.Message
    exit 1
}

# ───────────────────────────────────────────────────────────────────────────────



# The reference date is captured once at startup so all items in this run are
# judged against the same timestamp.
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
Write-Output "Folder Paths :"
foreach ($TargetPath in $ConfiguredFolderTargetPaths) {
    Write-Output "             - $TargetPath"
}
Write-Output "File Paths   :"
foreach ($TargetPath in $ConfiguredFileTargetPaths) {
    Write-Output "             - $TargetPath"
}
Write-Output "Max Age      : $MaxAgeDays days"
Write-Output "Cutoff Date  : $($CutoffDate.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Output "Dry Run      : $DryRunEnabled"
Write-Output "Run Time     : $($Now.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Output "----------------------------------------------"



# ── Process folder paths ─────────────────────────────────────────────────────

foreach ($TargetPath in $ConfiguredFolderTargetPaths) {
    Process-CleanupTarget `
        -TargetPath $TargetPath `
        -TargetType 'Folder' `
        -CutoffDate $CutoffDate `
        -DryRunEnabled $DryRunEnabled `
        -Now $Now `
        -DeletedCount ([ref]$DeletedCount) `
        -WouldDeleteCount ([ref]$WouldDeleteCount) `
        -ErrorCount ([ref]$ErrorCount) `
        -TotalSize ([ref]$TotalSize)
}



# ── Process file paths ────────────────────────────────────────────────────────

foreach ($TargetPath in $ConfiguredFileTargetPaths) {
    Process-CleanupTarget `
        -TargetPath $TargetPath `
        -TargetType 'File' `
        -CutoffDate $CutoffDate `
        -DryRunEnabled $DryRunEnabled `
        -Now $Now `
        -DeletedCount ([ref]$DeletedCount) `
        -WouldDeleteCount ([ref]$WouldDeleteCount) `
        -ErrorCount ([ref]$ErrorCount) `
        -TotalSize ([ref]$TotalSize)
}



# ── Summary ────────────────────────────────────────────────────────────────────

# Summary output is intentionally simple text because the RMM tool captures stdout
# and displays it in automation history. Keep labels stable for easy scanning.
$TotalSizeMB = [math]::Round(($TotalSize / 1MB), 2)

Write-Output ""
Write-Output "=============================================="
Write-Output "Summary"
Write-Output "=============================================="

if ($DryRunEnabled) {
    # In Dry Run mode, no deletion is attempted. Counts and sizes reflect only
    # items that were successfully enumerated and are eligible for removal.
    # Skipped items (enumeration errors) are excluded from both counts.
    Write-Output "Mode         : DRY RUN (nothing was deleted)"
    Write-Output "Would Delete : $WouldDeleteCount item(s)"
    Write-Output "Would Free   : ${TotalSizeMB} MB"
    Write-Output "Errors       : $ErrorCount"
} else {
    # In live mode, Deleted and Errors together show whether the run was clean,
    # partial, or failed. Space Freed reflects successful deletions only.
    Write-Output "Deleted      : $DeletedCount item(s)"
    Write-Output "Errors       : $ErrorCount"
    Write-Output "Space Freed  : ${TotalSizeMB} MB"
}

Write-Output "=============================================="



# ── Exit code ─────────────────────────────────────────────────────────────────

# The RMM tool uses the process exit code to determine automation success/failure.
# Any counted error means the cleanup was incomplete or misconfigured, so return
# 1. A clean run returns 0.
if ($ErrorCount -gt 0) {
    exit 1
}

exit 0
