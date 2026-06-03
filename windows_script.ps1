# SYSTEM - WINDOWS, DIRECT BACKBLAZE B2 BACKUPS

# This script is not as extensive as the Linux one since it was made much earlier,
# and I haven't had the time to add the same level of robustness to it. That said,
# it should be very easy to extend it as per your needs, since almost 90% of the
# functionality is already present.

# Make sure to init everything first by reading the wiki on the Duplicacy GitHub page.
# Use Windows Task Scheduler to run this script on a regular schedule.

# Make sure to have the Duplicacy binary in your PATH or specify the full path to the binary here
$duplicacyBinary = "duplicacy.exe"

# Comma separated list of folders to back up
$backupLocations = "C:\Users\<user>\Some\Backup", "G:\Some\Other\Backup"

# Pre-create the log file before the first time you run the script since 
# this script doesn't error check that.
$logFolder = "C:\Duplicacy\"
$logFileName = "duplicacy.log"
$logPath = ($logFolder + $logFileName)
# Size to roll over at in megabytes
$logMaxSize = 5mb
# Age after which to delete old logs (in days)
$logMaxAge = 30

# Function to roll over logs when they get too big
function Invoke-RolloverLogs
{
    # roll over by size
    if ((Get-Item $logPath).Length -gt $logMaxSize) {
        Write-Host "Rolling over logs"
        $currentDate = (Get-Date -UFormat %Y%m%d%H%M%S%Z)
        Rename-Item $logPath ($logPath + "." + $currentDate)
        Write-Output ("Rolled over logs at " + $currentDate >> $logPath)
    }
}

function Invoke-OldLogPurge
{
    $oldLogFileList = Get-ChildItem -Path $logFolder -Filter "*.log.*"

    foreach ($oldLogFile in $oldLogFileList) {
        $oldLogFilePath = ($logFolder + $oldLogFile)
        if ((Get-Item $oldLogFilePath).LastWriteTime.AddDays($logMaxAge) -lt (Get-Date)) {
            Write-Host ("Purging old log file: " + $oldLogFile)
            Remove-Item $oldLogFilePath
        }
    }
}

Invoke-RolloverLogs
Invoke-OldLogPurge

# New log day marker
Write-Output ("---") *>> $logPath
Write-Host "---"
Write-Host "Starting backup"

foreach ($location in $backupLocations) {
    Set-Location $location
    Write-Output ("running backups for " + $location + " at " + (Get-Date -UFormat %Y%m%d%T%Z)) *>> $logPath
    Write-Host ("Backing up " + $location)
    # Remove -threads 4 if backing up to a local drive
    & $duplicacyBinary backup -threads 4 -vss -stats *>> $logPath
    if ($LASTEXITCODE -eq 0) {
        Invoke-RestMethod 'https://uptime.domain.tld/api/push/xyz?status=up&msg=Backup-OK' | Out-Null
    } else {
        Write-Output ("ERROR in Backup!") *>> $logPath
        Write-Host "ERROR in Backup!" -ForegroundColor Red
        Invoke-RestMethod 'https://uptime.domain.tld/api/push/xyz?status=down&msg=Backup-NOT-OK' | Out-Null
    }
    
    # New log item marker
    Write-Output ("-") *>> $logPath
    Write-Host "-"
}

Write-Output ("running pruning from " + $location) *>> $logPath
Write-Host ("Running pruning from " + $location)
# Remove -threads 4 if pruning a local drive
& $duplicacyBinary prune -all -keep 0:360 -keep 30:180 -keep 7:30 -keep 1:7 -threads 4 *>> $logPath

# End log day marker
Write-Output ("---") *>> $logPath
Write-Host "---"
