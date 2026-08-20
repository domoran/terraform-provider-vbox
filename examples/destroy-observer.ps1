# destroy-observer.ps1
#
# Observes VirtualBox VM state EXTERNALLY (independent of the provider),
# e.g. while running `tofu destroy`, and writes timestamped state
# transitions to a log file. This lets us verify:
#
#   - when a VM actually reaches "poweroff" relative to destroy start
#   - whether destroy escalates to a hard poweroff (running -> poweroff
#     only after ~65s for a VM that ignores ACPI)
#   - when the VM disappears from the registry (unregister)
#   - leftover VM folders on disk after destroy
#
# Usage:
#   powershell -NoProfile -File destroy-observer.ps1 `
#     -Names "tf-destroy-a;tf-destroy-b" `
#     -IntervalSeconds 2 `
#     -LogFile observer.log [-StopAfterMinutes 15]
#
# NOTE: use ';' between names. PowerShell would interpret ',' as an array
# separator on the command line.
#
# Run it in a background terminal while terraform destroys, then kill
# it (or let -StopAfterMinutes expire) afterwards.

param(
    [Parameter(Mandatory = $true)]
    [string]$Names,

    [double]$IntervalSeconds = 2,

    [string]$LogFile = "observer.log",

    [double]$StopAfterMinutes = 0,
    [string]$BaseFolder = ""
)

# Accept "name1;name2" (semicolon-separated) for simple invocation from bash.
# NOTE: assign to a NEW variable - reassigning the [string]-typed parameter
# would coerce the array back to a string (joined with a space).
$NameList = @($Names -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })

$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
if (-not (Test-Path $VBoxManage)) {
    $found = Get-Command VBoxManage.exe -ErrorAction SilentlyContinue
    if ($found) { $VBoxManage = $found.Source }
    else { Write-Error "VBoxManage not found"; exit 1 }
}

function Get-Stamp {
    Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
}

function Add-Log([string]$msg) {
    "$((Get-Stamp)) $msg" | Out-File -FilePath $LogFile -Append -Encoding utf8
}

$startTime = Get-Date
Add-Log "observer started (names: $($NameList -join ' | '), interval: ${IntervalSeconds}s)"

while ($true) {
    if ($StopAfterMinutes -gt 0) {
        $elapsedMin = (New-TimeSpan -Start $startTime).TotalMinutes
        if ($elapsedMin -ge $StopAfterMinutes) {
            Add-Log "stop-after timeout reached, exiting"
            break
        }
    }

    $all = & $VBoxManage list vms 2>$null

    foreach ($n in $NameList) {
        $entry = $all | Where-Object { $_ -match [regex]::Escape($n) } | Select-Object -First 1
        if (-not $entry) {
            # Check for a leftover folder on disk
            $folderNote = ""
            if ($BaseFolder -ne "") {
                $dir = Join-Path $BaseFolder $n
                if (Test-Path $dir) {
                    $files = @(Get-ChildItem -Path $dir -Recurse -File -ErrorAction SilentlyContinue |
                        ForEach-Object { "{0}({1}KB)" -f $_.Name, [int]($_.Length / 1KB) })
                    $folderNote = " LEFTOVER-FOLDER files=[{0}]" -f ($files -join ", ")
                }
            }
            Add-Log "$n ABSENT$folderNote"
            continue
        }

        $uuid = ($entry -split '\{|\}') | Where-Object { $_ -match '^[0-9a-f]{8}-' } | Select-Object -First 1
        if (-not $uuid) {
            Add-Log "$n PARSE-ERROR ($entry)"
            continue
        }

        $info = & $VBoxManage showvminfo $uuid --machinereadable 2>$null
        $stateLine = $info | Where-Object { $_ -match '^VMState=' } | Select-Object -First 1
        if ($stateLine) {
            $state = ($stateLine -replace '^VMState="?', '').Trim().Trim('"')
        } else {
            $state = "PARSE-ERROR"
        }
        Add-Log "$n $state"
    }

    Start-Sleep -Seconds $IntervalSeconds
}
