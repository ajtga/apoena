#Requires -Version 5.1
# Apoena - Focus Session Logger & Wellness Reminder
# https://github.com/<YOUR_USER>/apoena

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    public struct LASTINPUTINFO {
        public uint cbSize;
        public uint dwTime;
    }

    [DllImport("user32.dll")]
    public static extern bool LockWorkStation();

    [DllImport("user32.dll")]
    public static extern bool FlashWindowEx(ref FLASHWINFO pwfi);
    [StructLayout(LayoutKind.Sequential)]
    public struct FLASHWINFO {
        public uint  cbSize;
        public IntPtr hwnd;
        public uint  dwFlags;
        public uint  uCount;
        public uint  dwTimeout;
    }
    public const uint FLASHW_ALL   = 3;   // caption + taskbar button
    public const uint FLASHW_TIMER = 4;   // flash continuously for uCount times
}
"@

# --- Single Instance Guard ---
$createdNew = $false
$global:mutex = New-Object System.Threading.Mutex($true, "Global\ApoenaMutex", [ref]$createdNew)
if (-not $createdNew) {
    [System.Windows.Forms.MessageBox]::Show(
        "Apoena is already running in the system tray.",
        "Apoena",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    [System.Environment]::Exit(0)
}

# --- Configuration ---
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$configPath = Join-Path $scriptDir "config.psd1"
$config = if (Test-Path $configPath) { Import-PowerShellDataFile $configPath } else { @{} }

$focusSessionDuration = if ($config.FocusSessionMinutes) { $config.FocusSessionMinutes * 60 } else { 20 * 60 }   # default: 20 minutes
$breakDuration = if ($config.BreakDurationSeconds) { $config.BreakDurationSeconds } else { 20 }     # default: 20 seconds
$quickBreakMinDuration = if ($config.QuickBreakMinMinutes) { $config.QuickBreakMinMinutes * 60 } else { 5 * 60 } # default: 5 minutes
$pauseMinDuration = if ($config.PauseMinMinutes) { $config.PauseMinMinutes * 60 } else { 5 * 60 } # default: 5 minutes
$idleThreshold = if ($config.IdleThresholdMinutes) { $config.IdleThresholdMinutes * 60 } else { 15 * 60 } # default: 15 minutes
$awayReasons = if ($config.AwayReasons) { $config.AwayReasons } else { @("Meeting", "Lunch", "Call", "Offline Work", "Coffee", "Rest", "Distraction", "End of Day", "Other") }
$quickBreakReasons = if ($config.QuickBreakReasons) { $config.QuickBreakReasons } else { @("Pee", "Poo", "Water", "Coffee", "Snack", "Stretch", "Other") }
$global:keyResultCategories = if ($config.KeyResultCategories) { $config.KeyResultCategories } else { @("Project", "Analysis", "KPI", "Dev", "Board Request", "Management Request", "Coordination Request", "Other") }
$logFile = Join-Path $scriptDir "apoena-log.csv"
$krsLogFile = Join-Path $scriptDir "apoena-krs-log.csv"

$global:manualInterrupt = $false
$global:sessionIndex = 0
$global:daySequence = 0
$global:lastLogDate = (Get-Date).Date
$lastBreak = [DateTime]::Now
$focusSessionStart = [DateTime]::Now

# --- Helper Functions ---
function Invoke-EnforcedBreak($durationSecs, $context) {
    [Win32]::LockWorkStation() | Out-Null
    
    if ($durationSecs -le 0) {
        return
    }

    $breakStart = [DateTime]::Now
    $global:sessionUnlocked = $false
    
    $handler = Register-ObjectEvent -InputObject ([Microsoft.Win32.SystemEvents]) -EventName "SessionSwitch" -Action {
        if ($Event.SourceEventArgs.Reason -eq 'SessionUnlock') {
            $global:sessionUnlocked = $true
        }
    }

    try {
        while ($true) {
            [System.Windows.Forms.Application]::DoEvents()
            
            $elapsed = ([DateTime]::Now - $breakStart).TotalSeconds
            if ($elapsed -ge $durationSecs) {
                break
            }
            
            if ($global:sessionUnlocked) {
                $global:sessionUnlocked = $false
                $remaining = [math]::Round($durationSecs - $elapsed)
                
                $form = New-Object System.Windows.Forms.Form
                $form.Size = New-Object System.Drawing.Size(350, 180)
                $form.StartPosition = "CenterScreen"
                $form.TopMost = $true
                $form.FormBorderStyle = "FixedDialog"
                $form.MaximizeBox = $false
                $form.MinimizeBox = $false
                
                if ($context -eq "Pause") {
                    $form.Text = "Minimum Pause Enforced"
                } else {
                    $form.Text = "Break Not Over"
                }
                
                $lbl = New-Object System.Windows.Forms.Label
                $lbl.Location = New-Object System.Drawing.Point(20, 20)
                $lbl.Size = New-Object System.Drawing.Size(300, 70)
                $form.Controls.Add($lbl)
                
                $btn = New-Object System.Windows.Forms.Button
                $btn.Text = "Lock Now"
                $btn.Location = New-Object System.Drawing.Point(120, 100)
                $btn.Add_Click({ $form.Close() })
                $form.Controls.Add($btn)
                
                $form.Show()
                
                $alertStart = [DateTime]::Now
                while ($form.Visible) {
                    [System.Windows.Forms.Application]::DoEvents()
                    $alertElapsed = ([DateTime]::Now - $alertStart).TotalSeconds
                    $alertRemaining = 5 - $alertElapsed
                    if ($alertRemaining -le 0) {
                        $form.Close()
                        break
                    }
                    if ($context -eq "Pause") {
                        $lbl.Text = "The minimum pause duration has not elapsed yet. $remaining seconds remaining.`n`nLocking again in $([math]::Ceiling($alertRemaining))s..."
                    } else {
                        $lbl.Text = "Your break is not over yet. $remaining seconds remaining.`n`nLocking again in $([math]::Ceiling($alertRemaining))s..."
                    }
                    Start-Sleep -Milliseconds 100
                }
                
                $form.Dispose()
                
                [Win32]::LockWorkStation() | Out-Null
            }
            Start-Sleep -Milliseconds 500
        }
    }
    finally {
        Unregister-Event -SourceIdentifier $handler.Name
    }
}

function Get-ScheduleContext {
    $now = Get-Date
    $day = $now.DayOfWeek
    $time = $now.TimeOfDay
    if ($day -eq 'Saturday' -or $day -eq 'Sunday') { return "Weekend" }
    
    $start = [TimeSpan]::FromHours(8)
    $lunchStart = [TimeSpan]::FromHours(12)
    $lunchEnd = [TimeSpan]::FromHours(13)
    $end = if ($day -eq 'Friday') { [TimeSpan]::FromHours(17) } else { [TimeSpan]::FromHours(18) }

    if ($time -lt $start) { return "Early Arrival" }
    if ($time -ge $lunchStart -and $time -lt $lunchEnd) { return "Lunch Time" }
    if ($time -ge $end) { return "Overtime" }
    return "Core Hours"
}

function ConvertTo-CsvSafe($text) {
    if ($null -eq $text) { return '""' }
    $escaped = $text -replace '"', '""'
    return "`"$escaped`""
}

function Write-Log($eventCategory, $eventDetail, $durationSecs, $accomplished, $planned, $notes, $logDurSecs, $context, $keyResultId, $customTimestamp = $null, $isDistraction = $false, $globalId = "") {
    # Reset day sequence at midnight
    $logDate = if ($customTimestamp) { [datetime]::ParseExact($customTimestamp, "yyyy-MM-dd HH:mm:ss", $null).Date } else { (Get-Date).Date }
    if ($logDate -ne $global:lastLogDate) {
        $global:daySequence = 0
        $global:lastLogDate = $logDate
    }

    $global:sessionIndex++
    $global:daySequence++

    $stamp = if ($customTimestamp) { $customTimestamp } else { (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }
    $tzOffset = (Get-Date).ToString("zzz")
    
    # Keep 3 decimal places for millisecond precision
    $duration = ([math]::Round($durationSecs, 3)).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $logDur = ([math]::Round($logDurSecs, 3)).ToString([System.Globalization.CultureInfo]::InvariantCulture)

    $safeCategory = ConvertTo-CsvSafe $eventCategory
    $safeDetail = ConvertTo-CsvSafe $eventDetail
    $safeAccomplished = ConvertTo-CsvSafe $accomplished
    $safePlanned = ConvertTo-CsvSafe $planned
    $safeNotes = ConvertTo-CsvSafe $notes
    $safeContext = ConvertTo-CsvSafe $context

    $fields = @(
        $stamp,
        $tzOffset,
        $safeCategory,
        $safeDetail,
        $global:sessionIndex.ToString([System.Globalization.CultureInfo]::InvariantCulture),
        $global:daySequence.ToString([System.Globalization.CultureInfo]::InvariantCulture),
        $duration,
        $safeAccomplished,
        $safePlanned,
        $safeNotes,
        $logDur,
        $safeContext,
        (ConvertTo-CsvSafe $keyResultId),
        (ConvertTo-CsvSafe $isDistraction.ToString()),
        (ConvertTo-CsvSafe $globalId.ToString())
    )
    $row = $fields -join ','

    try {
        $row | Out-File $logFile -Append -Encoding UTF8
    }
    catch {
        Write-Warning "Apoena: Failed to write log - $($_.Exception.Message)"
    }
}

function Invoke-EndOfDay($reason) {
    if ($reason -eq 'End of Day') {
        [System.Windows.Forms.MessageBox]::Show("Great work today! Goodbye, get some rest, and see you soon.", "Shift Complete", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        if ($trayIcon) {
            $trayIcon.Visible = $false
            $trayIcon.Dispose()
        }
        [System.Environment]::Exit(0)
    }
}

function Get-FormattedDuration($seconds) {
    if ($seconds -ge 60) {
        $mins = [math]::Round($seconds / 60)
        $suffix = ""
        if ($mins -ne 1) { $suffix = "s" }
        return "$mins minute$suffix"
    }
    else {
        $suffix = ""
        if ($seconds -ne 1) { $suffix = "s" }
        return "$seconds second$suffix"
    }
}

function Get-AllKeyResultsMap {
    if (-not (Test-Path $krsLogFile)) { return @{} }
    $content = Get-Content $krsLogFile | Select-Object -Skip 1
    $map = @{}
    foreach ($line in $content) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $parsed = $line | ConvertFrom-Csv -Header "Timestamp", "Date", "KeyResultID", "Category", "Description", "Status", "GlobalID"
            $status = if ($parsed.Status) { $parsed.Status } else { "Active" }
            $gIdVal = $parsed.GlobalID
            if (-not [string]::IsNullOrWhiteSpace($gIdVal)) {
                $gId = [int]$gIdVal
                $map[$gId] = @{
                    Timestamp   = $parsed.Timestamp
                    Date        = $parsed.Date
                    KeyResultID = $parsed.KeyResultID
                    Category    = $parsed.Category
                    Description = $parsed.Description
                    Status      = $status
                    GlobalID    = $gId
                }
            }
        }
        catch { }
    }
    return $map
}

function Get-TodayKeyResults($includeCompleted = $false) {
    if (-not (Test-Path $krsLogFile)) { return @() }
    $todayStr = (Get-Date).ToString("yyyy-MM-dd")
    $map = Get-AllKeyResultsMap
    
    $todayGlobalIds = @{}
    $content = Get-Content $krsLogFile | Select-Object -Skip 1
    foreach ($line in $content) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $parsed = $line | ConvertFrom-Csv -Header "Timestamp", "Date", "KeyResultID", "Category", "Description", "Status", "GlobalID"
            if ($parsed.Date -eq $todayStr -and $parsed.GlobalID) {
                $todayGlobalIds[[int]$parsed.GlobalID] = $parsed.KeyResultID
            }
        }
        catch { }
    }
    
    $krs = @()
    foreach ($gId in $todayGlobalIds.Keys) {
        $gIdInt = [int]$gId
        $latest = $map[$gIdInt]
        if ($latest -and ($includeCompleted -or $latest.Status -eq 'Active')) {
            $krCopy = @{
                Timestamp   = $latest.Timestamp
                Date        = $latest.Date
                KeyResultID = $todayGlobalIds[$gIdInt]
                Category    = $latest.Category
                Description = $latest.Description
                Status      = $latest.Status
                GlobalID    = $gIdInt
            }
            $krs += [PSCustomObject]$krCopy
        }
    }
    return $krs
}

function Add-KeyResult($category, $description, $globalId = $null, $status = "Active") {
    $map = Get-AllKeyResultsMap
    $newGlobalId = $globalId
    if ($null -eq $newGlobalId) {
        $maxGlobalId = 0
        foreach ($gId in $map.Keys) {
            if ($gId -gt $maxGlobalId) { $maxGlobalId = $gId }
        }
        $newGlobalId = $maxGlobalId + 1
    }

    $todayStr = (Get-Date).ToString("yyyy-MM-dd")
    $existingTodayKr = $null
    if ($null -ne $globalId) {
        if (-not (Test-Path $krsLogFile)) { $existingTodayKr = $null }
        else {
            $content = Get-Content $krsLogFile | Select-Object -Skip 1
            foreach ($line in $content) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    $parsed = $line | ConvertFrom-Csv -Header "Timestamp", "Date", "KeyResultID", "Category", "Description", "Status", "GlobalID"
                    if ($parsed.Date -eq $todayStr -and $parsed.GlobalID -eq $globalId) {
                        $existingTodayKr = $parsed.KeyResultID
                        break
                    }
                } catch {}
            }
        }
    }

    $krId = $existingTodayKr
    if ($null -eq $krId) {
        $maxTodayIndex = 0
        if (Test-Path $krsLogFile) {
            $content = Get-Content $krsLogFile | Select-Object -Skip 1
            foreach ($line in $content) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    $parsed = $line | ConvertFrom-Csv -Header "Timestamp", "Date", "KeyResultID", "Category", "Description", "Status", "GlobalID"
                    if ($parsed.Date -eq $todayStr -and $parsed.KeyResultID -match 'KR-(\d+)') {
                        $idx = [int]$matches[1]
                        if ($idx -gt $maxTodayIndex) { $maxTodayIndex = $idx }
                    }
                } catch {}
            }
        }
        $nextIdx = $maxTodayIndex + 1
        $krId = "KR-$nextIdx"
    }

    $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $dateStr = (Get-Date).ToString("yyyy-MM-dd")
    
    $safeCat = ConvertTo-CsvSafe $category
    $safeDesc = ConvertTo-CsvSafe $description
    $safeStatus = ConvertTo-CsvSafe $status
    
    $row = "$stamp,$dateStr,$krId,$safeCat,$safeDesc,$safeStatus,$newGlobalId"
    $row | Out-File $krsLogFile -Append -Encoding UTF8
    
    return $krId
}

# --- Initialization, Crash Detection & Same-Day Restart ---
$isSameDayRestart = $false
if (-not (Test-Path $krsLogFile)) {
    "Timestamp,Date,KeyResultID,Category,Description,Status,GlobalID" | Out-File $krsLogFile -Encoding UTF8
}
else {
    $firstLine = Get-Content $krsLogFile -TotalCount 1
    if ($firstLine -notmatch "Status" -or $firstLine -notmatch "GlobalID") {
        $content = Get-Content $krsLogFile
        $content[0] = "Timestamp,Date,KeyResultID,Category,Description,Status,GlobalID"
        
        $uniqueKrs = @{}
        $globalCounter = 1
        
        for ($i = 1; $i -lt $content.Count; $i++) {
            $line = $content[$i]
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $parsed = $line | ConvertFrom-Csv -Header "Timestamp", "Date", "KeyResultID", "Category", "Description", "Status", "GlobalID"
                $descKey = "$($parsed.Category)|$($parsed.Description)"
                if (-not $uniqueKrs.ContainsKey($descKey)) {
                    $uniqueKrs[$descKey] = $globalCounter
                    $globalCounter++
                }
                $gId = $uniqueKrs[$descKey]
                $status = if ($parsed.Status) { $parsed.Status } else { "Active" }
                $safeCategory = ConvertTo-CsvSafe $parsed.Category
                $safeDesc = ConvertTo-CsvSafe $parsed.Description
                $content[$i] = "$($parsed.Timestamp),$($parsed.Date),$($parsed.KeyResultID),$safeCategory,$safeDesc,$status,$gId"
            } catch {
                $content[$i] = $line + ",Active,1"
            }
        }
        $content | Set-Content $krsLogFile -Encoding UTF8
    }
}

if (-not (Test-Path $logFile)) {
    "Timestamp,TimezoneOffset,EventCategory,EventDetail,SessionIndex,DaySequence,DurationSeconds,Accomplished,Planned,Notes,LoggingDurationSecs,ScheduleContext,KeyResultID,IsDistraction,GlobalID" | Out-File $logFile -Encoding UTF8
}
else {
    $firstLine = Get-Content $logFile -TotalCount 1
    if ($firstLine -notmatch "KeyResultID") {
        $content = Get-Content $logFile
        $content[0] = $content[0] + ",KeyResultID,IsDistraction,GlobalID"
        $content | Set-Content $logFile -Encoding UTF8
    }
    elseif ($firstLine -notmatch "IsDistraction") {
        $content = Get-Content $logFile
        $content[0] = $content[0] + ",IsDistraction,GlobalID"
        $content | Set-Content $logFile -Encoding UTF8
    }
    elseif ($firstLine -notmatch "GlobalID") {
        $content = Get-Content $logFile
        $content[0] = $content[0] + ",GlobalID"
        $content | Set-Content $logFile -Encoding UTF8
    }

    $lastLine = Get-Content $logFile -Tail 1
    if ($lastLine -match ',') {
        $parts = $lastLine -split ','

        # Detect same-day restart and restore counters
        $lastTimestamp = $parts[0]
        try {
            $lastDate = [datetime]::ParseExact($lastTimestamp, "yyyy-MM-dd HH:mm:ss", $null).Date
            if ($lastDate -eq (Get-Date).Date) {
                $isSameDayRestart = $true
                $global:sessionIndex = [int]$parts[4]
                $global:daySequence = [int]$parts[5]
            }
            else {
                $global:sessionIndex = [int]$parts[4]
                $global:daySequence = [int]$parts[5]
                $global:lastLogDate = $lastDate
            }
        }
        catch { }

        # Crash detection
        $lastEvent = $parts[2].Trim('"')
        $lastDetail = $parts[3].Trim('"')
        if ($lastEvent -ne 'System' -or $lastDetail -notmatch 'Exit') {
            # Previous session did not exit cleanly
            if ($lastDate -eq (Get-Date).Date) {
                Write-Log "System" "Unexpected Exit" 0 "" "" "Detected on startup" 0 (Get-ScheduleContext) ""
            }
            else {
                # Log with yesterday's timestamp (last log time + 1 second) to keep history accurate and prevent same-day restart pollution
                $lastDateTime = [datetime]::ParseExact($lastTimestamp, "yyyy-MM-dd HH:mm:ss", $null)
                $crashTimestamp = $lastDateTime.AddSeconds(1).ToString("yyyy-MM-dd HH:mm:ss")
                Write-Log "System" "Unexpected Exit" 0 "" "" "Detected on startup" 0 (Get-ScheduleContext) "" $crashTimestamp
            }
        }
    }
}

# --- UI Forms ---
function Show-KeyResultsForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Daily Key Results Planning"
    $form.Size = New-Object System.Drawing.Size(420, 380)
    $form.StartPosition = "CenterScreen"
    $form.TopMost = $true
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $lblList = New-Object System.Windows.Forms.Label
    $lblList.Text = "Today's Active Key Results:"
    $lblList.Location = New-Object System.Drawing.Point(10, 10)
    $lblList.AutoSize = $true
    $form.Controls.Add($lblList)

    $lstKrs = New-Object System.Windows.Forms.ListBox
    $lstKrs.Location = New-Object System.Drawing.Point(10, 30)
    $lstKrs.Size = New-Object System.Drawing.Size(380, 100)
    
    $loadKrs = {
        $lstKrs.Items.Clear()
        $krs = Get-TodayKeyResults -IncludeCompleted $true
        foreach ($kr in $krs) {
            $statusPrefix = if ($kr.Status -eq 'Done') { "[Done] " } else { "" }
            $lstKrs.Items.Add("$statusPrefix[$($kr.KeyResultID)] ($($kr.Category)) $($kr.Description)") | Out-Null
        }
    }
    &$loadKrs
    $form.Controls.Add($lstKrs)

    $lblCat = New-Object System.Windows.Forms.Label
    $lblCat.Text = "Category:"
    $lblCat.Location = New-Object System.Drawing.Point(10, 140)
    $lblCat.AutoSize = $true
    $form.Controls.Add($lblCat)

    $cmbCat = New-Object System.Windows.Forms.ComboBox
    $cmbCat.Items.AddRange($global:keyResultCategories)
    if ($cmbCat.Items.Count -gt 0) { $cmbCat.SelectedIndex = 0 }
    $cmbCat.Location = New-Object System.Drawing.Point(10, 160)
    $cmbCat.Size = New-Object System.Drawing.Size(120, 20)
    $cmbCat.DropDownStyle = 'DropDownList'
    $form.Controls.Add($cmbCat)

    $lblDesc = New-Object System.Windows.Forms.Label
    $lblDesc.Text = "Description:"
    $lblDesc.Location = New-Object System.Drawing.Point(140, 140)
    $lblDesc.AutoSize = $true
    $form.Controls.Add($lblDesc)

    $txtDesc = New-Object System.Windows.Forms.TextBox
    $txtDesc.Location = New-Object System.Drawing.Point(140, 160)
    $txtDesc.Size = New-Object System.Drawing.Size(170, 20)
    $form.Controls.Add($txtDesc)

    $lblPrev = New-Object System.Windows.Forms.Label
    $lblPrev.Text = "Activate Unfinished Key Result:"
    $lblPrev.Location = New-Object System.Drawing.Point(10, 195)
    $lblPrev.AutoSize = $true
    $form.Controls.Add($lblPrev)

    $cmbPrev = New-Object System.Windows.Forms.ComboBox
    $cmbPrev.Location = New-Object System.Drawing.Point(10, 215)
    $cmbPrev.Size = New-Object System.Drawing.Size(300, 20)
    $cmbPrev.DropDownStyle = 'DropDownList'
    $form.Controls.Add($cmbPrev)

    $btnActivate = New-Object System.Windows.Forms.Button
    $btnActivate.Text = "Activate"
    $btnActivate.Location = New-Object System.Drawing.Point(320, 213)
    $btnActivate.Size = New-Object System.Drawing.Size(70, 24)
    $form.Controls.Add($btnActivate)

    $loadPrevKrs = {
        $cmbPrev.Items.Clear()
        $map = Get-AllKeyResultsMap
        $todayIds = @{}
        $todayKrs = Get-TodayKeyResults -IncludeCompleted $true
        foreach ($kr in $todayKrs) {
            $todayIds[$kr.GlobalID] = $true
        }
        
        $unfinished = $map.Values | Where-Object { $_.Status -eq 'Active' -and -not $todayIds[$_.GlobalID] }
        foreach ($kr in $unfinished) {
            $cmbPrev.Items.Add("[Global ID: $($kr.GlobalID)] ($($kr.Category)) $($kr.Description)") | Out-Null
        }
        if ($cmbPrev.Items.Count -gt 0) {
            $cmbPrev.SelectedIndex = 0
            $btnActivate.Enabled = $true
        } else {
            $btnActivate.Enabled = $false
        }
    }
    &$loadPrevKrs

    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text = "Add"
    $btnAdd.Location = New-Object System.Drawing.Point(320, 158)
    $btnAdd.Size = New-Object System.Drawing.Size(70, 24)
    $btnAdd.Add_Click({
            if ([string]::IsNullOrWhiteSpace($txtDesc.Text)) {
                [System.Windows.Forms.MessageBox]::Show("Please enter a description.", "Required", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                return
            }
            $cat = if ($cmbCat.SelectedItem) { $cmbCat.SelectedItem.ToString() } else { "Other" }
            Add-KeyResult $cat $txtDesc.Text | Out-Null
            &$loadKrs
            &$loadPrevKrs
            $txtDesc.Text = ""
        })
    $form.Controls.Add($btnAdd)

    $btnActivate.Add_Click({
        if ($cmbPrev.SelectedItem) {
            if ($cmbPrev.SelectedItem.ToString() -match "\[Global ID: (\d+)\]") {
                $gId = [int]$matches[1]
                $map = Get-AllKeyResultsMap
                $kr = $map[$gId]
                Add-KeyResult $kr.Category $kr.Description $gId "Active" | Out-Null
                &$loadKrs
                &$loadPrevKrs
            }
        }
    })

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close / Start Day"
    $btnClose.Location = New-Object System.Drawing.Point(150, 290)
    $btnClose.Size = New-Object System.Drawing.Size(120, 30)
    $btnClose.Add_Click({
            $todayKrs = Get-TodayKeyResults -IncludeCompleted $true
            if ($todayKrs.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show(
                    $form,
                    "You must define at least one Key Result to start your day.",
                    "Key Result Required",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                ) | Out-Null
            }
            else {
                $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
                $form.Close()
            }
        })
    $form.Controls.Add($btnClose)
    $form.AcceptButton = $btnClose

    $form.Add_FormClosing({
            param($evtSender, $e)
            if ($form.DialogResult -ne [System.Windows.Forms.DialogResult]::OK) {
                $todayKrs = Get-TodayKeyResults -IncludeCompleted $true
                if ($todayKrs.Count -eq 0) {
                    $confirm = [System.Windows.Forms.MessageBox]::Show(
                        $form,
                        "Closing this window will exit Apoena completely. Are you sure you want to exit?",
                        "Exit Apoena?",
                        [System.Windows.Forms.MessageBoxButtons]::YesNo,
                        [System.Windows.Forms.MessageBoxIcon]::Question
                    )
                    if ($confirm -eq [System.Windows.Forms.DialogResult]::No) {
                        $e.Cancel = $true
                    }
                }
            }
        })

    $form.ShowDialog() | Out-Null
}

function Show-QuickAddKRForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Add Key Result"
    $form.Size = New-Object System.Drawing.Size(350, 150)
    $form.StartPosition = "CenterScreen"
    $form.TopMost = $true
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $lblCat = New-Object System.Windows.Forms.Label
    $lblCat.Text = "Category:"
    $lblCat.Location = New-Object System.Drawing.Point(10, 10)
    $lblCat.AutoSize = $true
    $form.Controls.Add($lblCat)

    $cmbCat = New-Object System.Windows.Forms.ComboBox
    $cmbCat.Items.AddRange($global:keyResultCategories)
    if ($cmbCat.Items.Count -gt 0) { $cmbCat.SelectedIndex = 0 }
    $cmbCat.Location = New-Object System.Drawing.Point(10, 30)
    $cmbCat.Size = New-Object System.Drawing.Size(120, 20)
    $cmbCat.DropDownStyle = 'DropDownList'
    $form.Controls.Add($cmbCat)

    $lblDesc = New-Object System.Windows.Forms.Label
    $lblDesc.Text = "Description:"
    $lblDesc.Location = New-Object System.Drawing.Point(140, 10)
    $lblDesc.AutoSize = $true
    $form.Controls.Add($lblDesc)

    $txtDesc = New-Object System.Windows.Forms.TextBox
    $txtDesc.Location = New-Object System.Drawing.Point(140, 30)
    $txtDesc.Size = New-Object System.Drawing.Size(180, 20)
    $form.Controls.Add($txtDesc)

    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text = "Add Key Result"
    $btnAdd.Location = New-Object System.Drawing.Point(120, 70)
    $btnAdd.Size = New-Object System.Drawing.Size(100, 30)
    $btnAdd.Add_Click({
            if ([string]::IsNullOrWhiteSpace($txtDesc.Text)) {
                [System.Windows.Forms.MessageBox]::Show("Please enter a description.", "Required", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                return
            }
            $cat = if ($cmbCat.SelectedItem) { $cmbCat.SelectedItem.ToString() } else { "Other" }
            $this.Parent.Tag = Add-KeyResult $cat $txtDesc.Text
            $this.Parent.DialogResult = [System.Windows.Forms.DialogResult]::OK
        })
    $form.Controls.Add($btnAdd)
    $form.AcceptButton = $btnAdd

    $form.ShowDialog() | Out-Null
    return $form.Tag
}

function Show-StartSessionForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Start Your First Focus Session"
    $form.Size = New-Object System.Drawing.Size(380, 240)
    $form.StartPosition = "CenterScreen"
    $form.TopMost = $true
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Welcome to Apoena! Select your starting Key Result and task:"
    $lbl.Location = New-Object System.Drawing.Point(10, 10)
    $lbl.Size = New-Object System.Drawing.Size(340, 35)
    $form.Controls.Add($lbl)

    $lblKr = New-Object System.Windows.Forms.Label
    $lblKr.Text = "Key Result:"
    $lblKr.Location = New-Object System.Drawing.Point(10, 60)
    $lblKr.Size = New-Object System.Drawing.Size(80, 20)
    $form.Controls.Add($lblKr)

    $cmbKr = New-Object System.Windows.Forms.ComboBox
    $cmbKr.Location = New-Object System.Drawing.Point(100, 58)
    $cmbKr.Size = New-Object System.Drawing.Size(250, 20)
    $cmbKr.DropDownStyle = 'DropDownList'
    
    $krs = Get-TodayKeyResults -IncludeCompleted $false
    foreach ($kr in $krs) {
        $cmbKr.Items.Add("[$($kr.KeyResultID)] $($kr.Description)") | Out-Null
    }
    $cmbKr.Items.Add("[None] Unplanned / Distraction") | Out-Null
    $cmbKr.SelectedIndex = 0
    $form.Controls.Add($cmbKr)

    $lblPlan = New-Object System.Windows.Forms.Label
    $lblPlan.Text = "Plan:"
    $lblPlan.Location = New-Object System.Drawing.Point(10, 95)
    $lblPlan.Size = New-Object System.Drawing.Size(80, 20)
    $form.Controls.Add($lblPlan)

    $txtPlan = New-Object System.Windows.Forms.TextBox
    $txtPlan.Location = New-Object System.Drawing.Point(100, 93)
    $txtPlan.Size = New-Object System.Drawing.Size(250, 20)
    $form.Controls.Add($txtPlan)

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = "Start Focus"
    $btn.Location = New-Object System.Drawing.Point(130, 140)
    $btn.Size = New-Object System.Drawing.Size(100, 30)
    $btn.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btn)
    $form.AcceptButton = $btn

    $validate = {
        $btn.Enabled = (-not [string]::IsNullOrWhiteSpace($txtPlan.Text))
    }
    $txtPlan.Add_TextChanged({ &$validate })
    &$validate

    $txtPlan.Add_KeyDown({
        if ($_.KeyCode -eq 'Enter') {
            $_.SuppressKeyPress = $true
            if ($btn.Enabled) { $btn.PerformClick() }
        }
    })

    $form.ShowDialog() | Out-Null
    
    $selectedKrId = ""
    $selectedGlobalId = ""
    if ($cmbKr.SelectedItem -and $cmbKr.SelectedItem.ToString() -ne "[None] Unplanned / Distraction") {
        if ($cmbKr.SelectedItem.ToString() -match "\[(.*?)\]") {
            $selectedKrId = $matches[1]
            $todayKrs = Get-TodayKeyResults -IncludeCompleted $true
            $matched = $todayKrs | Where-Object { $_.KeyResultID -eq $selectedKrId }
            if ($matched) {
                $selectedGlobalId = $matched.GlobalID
            }
        }
    }

    return @{ KeyResultID = $selectedKrId; GlobalID = $selectedGlobalId; Planned = $txtPlan.Text }
}

function Show-ResumedSessionForm {
    $formStart = [DateTime]::Now
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Welcome Back"
    $form.Size = New-Object System.Drawing.Size(380, 320)
    $form.StartPosition = "CenterScreen"
    $form.TopMost = $true
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Apoena was already running today. What happened since it closed?"
    $lbl.Location = New-Object System.Drawing.Point(10, 10)
    $lbl.Size = New-Object System.Drawing.Size(340, 35)
    $form.Controls.Add($lbl)

    $txtContext = New-Object System.Windows.Forms.TextBox
    $txtContext.Location = New-Object System.Drawing.Point(10, 45)
    $txtContext.Size = New-Object System.Drawing.Size(340, 20)
    $form.Controls.Add($txtContext)

    $lblSep = New-Object System.Windows.Forms.Label
    $lblSep.Text = "--- Plan Next Focus Session ---"
    $lblSep.Location = New-Object System.Drawing.Point(10, 75)
    $lblSep.Size = New-Object System.Drawing.Size(340, 20)
    $lblSep.ForeColor = [System.Drawing.Color]::Gray
    $lblSep.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $form.Controls.Add($lblSep)

    $lblKr = New-Object System.Windows.Forms.Label
    $lblKr.Text = "Key Result to focus on:"
    $lblKr.Location = New-Object System.Drawing.Point(10, 105)
    $lblKr.Size = New-Object System.Drawing.Size(340, 15)
    $form.Controls.Add($lblKr)

    $cmbKr = New-Object System.Windows.Forms.ComboBox
    $cmbKr.Location = New-Object System.Drawing.Point(10, 125)
    $cmbKr.Size = New-Object System.Drawing.Size(340, 20)
    $cmbKr.DropDownStyle = 'DropDownList'
    
    $krs = Get-TodayKeyResults -IncludeCompleted $false
    foreach ($kr in $krs) {
        $cmbKr.Items.Add("[$($kr.KeyResultID)] $($kr.Description)") | Out-Null
    }
    $cmbKr.Items.Add("[None] Unplanned / Distraction") | Out-Null
    $cmbKr.SelectedIndex = 0
    $form.Controls.Add($cmbKr)

    $lblPlan = New-Object System.Windows.Forms.Label
    $lblPlan.Text = "What do you plan to do?"
    $lblPlan.Location = New-Object System.Drawing.Point(10, 160)
    $lblPlan.Size = New-Object System.Drawing.Size(340, 15)
    $form.Controls.Add($lblPlan)

    $txtPlan = New-Object System.Windows.Forms.TextBox
    $txtPlan.Location = New-Object System.Drawing.Point(10, 180)
    $txtPlan.Size = New-Object System.Drawing.Size(340, 20)
    $form.Controls.Add($txtPlan)

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = "Resume"
    $btn.Location = New-Object System.Drawing.Point(130, 225)
    $btn.Size = New-Object System.Drawing.Size(100, 30)
    $btn.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btn)
    $form.AcceptButton = $btn

    $validate = {
        $btn.Enabled = (-not [string]::IsNullOrWhiteSpace($txtContext.Text) -and -not [string]::IsNullOrWhiteSpace($txtPlan.Text))
    }
    $txtContext.Add_TextChanged({ &$validate })
    $txtPlan.Add_TextChanged({ &$validate })
    &$validate

    $txtContext.Add_KeyDown({
        if ($_.KeyCode -eq 'Enter') {
            $_.SuppressKeyPress = $true
            $form.SelectNextControl($txtContext, $true, $true, $true, $true) | Out-Null
        }
    })
    $txtPlan.Add_KeyDown({
        if ($_.KeyCode -eq 'Enter') {
            $_.SuppressKeyPress = $true
            if ($btn.Enabled) { $btn.PerformClick() }
        }
    })

    $form.ShowDialog() | Out-Null
    $logDur = ([DateTime]::Now - $formStart).TotalSeconds

    $selectedKrId = ""
    $selectedGlobalId = ""
    if ($cmbKr.SelectedItem -and $cmbKr.SelectedItem.ToString() -ne "[None] Unplanned / Distraction") {
        if ($cmbKr.SelectedItem.ToString() -match "\[(.*?)\]") {
            $selectedKrId = $matches[1]
            $todayKrs = Get-TodayKeyResults -IncludeCompleted $true
            $matched = $todayKrs | Where-Object { $_.KeyResultID -eq $selectedKrId }
            if ($matched) {
                $selectedGlobalId = $matched.GlobalID
            }
        }
    }

    return @{
        Context       = $txtContext.Text
        LogDuration   = $logDur
        KeyResultID   = $selectedKrId
        GlobalID      = $selectedGlobalId
        Planned       = $txtPlan.Text
    }
}

function Show-FocusSessionForm {
    $formStart = [DateTime]::Now
    $form = New-Object System.Windows.Forms.Form
    $focusSessionTimeStr = Get-FormattedDuration $focusSessionDuration
    $form.Text = "Focus Session Complete! ($focusSessionTimeStr)"
    $form.Size = New-Object System.Drawing.Size(430, 385)
    $form.StartPosition = "CenterScreen"
    $form.TopMost = $true
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ControlBox = $false

    # 1. Which Key Result did you focus on?
    $lblKr = New-Object System.Windows.Forms.Label
    $lblKr.Text = "Which Key Result did you focus on?"
    $lblKr.Location = New-Object System.Drawing.Point(10, 10)
    $lblKr.AutoSize = $true
    $form.Controls.Add($lblKr)

    $cmbKr = New-Object System.Windows.Forms.ComboBox
    $cmbKr.Location = New-Object System.Drawing.Point(10, 30)
    $cmbKr.Size = New-Object System.Drawing.Size(350, 20)
    $cmbKr.DropDownStyle = 'DropDownList'
    
    $loadCmbKrs = {
        $cmbKr.Items.Clear()
        $krs = Get-TodayKeyResults -IncludeCompleted $false
        
        # Ensure the current active KR of this finished session is included
        if ($global:currentKrId) {
            $exists = $false
            foreach ($kr in $krs) {
                if ($kr.KeyResultID -eq $global:currentKrId) { $exists = $true; break }
            }
            if (-not $exists) {
                $matchedToday = Get-TodayKeyResults -IncludeCompleted $true | Where-Object { $_.KeyResultID -eq $global:currentKrId }
                if ($matchedToday) {
                    $krs += $matchedToday
                }
            }
        }

        foreach ($kr in $krs) {
            $statusPrefix = if ($kr.Status -eq 'Done') { "[Done] " } else { "" }
            $cmbKr.Items.Add("$statusPrefix[$($kr.KeyResultID)] $($kr.Description)") | Out-Null
        }
        
        if ($global:currentKrId) {
            for ($i = 0; $i -lt $cmbKr.Items.Count; $i++) {
                if ($cmbKr.Items[$i] -match "\[$($global:currentKrId)\]") {
                    $cmbKr.SelectedIndex = $i
                    break
                }
            }
        }
    }
    &$loadCmbKrs
    $form.Controls.Add($cmbKr)

    $btnAddKr = New-Object System.Windows.Forms.Button
    $btnAddKr.Text = "+"
    $btnAddKr.Location = New-Object System.Drawing.Point(370, 29)
    $btnAddKr.Size = New-Object System.Drawing.Size(30, 22)
    $btnAddKr.Add_Click({
            $newId = Show-QuickAddKRForm
            if ($newId) {
                &$loadCmbKrs
                for ($i = 0; $i -lt $cmbKr.Items.Count; $i++) {
                    if ($cmbKr.Items[$i] -match "\[$newId\]") {
                        $cmbKr.SelectedIndex = $i
                        break
                    }
                }
            }
        })
    $form.Controls.Add($btnAddKr)

    # 2. Checkboxes (Unplanned & Mark completed)
    $chkUnplanned = New-Object System.Windows.Forms.CheckBox
    $chkUnplanned.Text = "Unplanned / Distracted"
    $chkUnplanned.Location = New-Object System.Drawing.Point(10, 55)
    $chkUnplanned.Size = New-Object System.Drawing.Size(180, 20)
    $form.Controls.Add($chkUnplanned)

    $chkMarkDone = New-Object System.Windows.Forms.CheckBox
    $chkMarkDone.Text = "Mark Key Result as completed"
    $chkMarkDone.Location = New-Object System.Drawing.Point(200, 55)
    $chkMarkDone.Size = New-Object System.Drawing.Size(220, 20)
    $chkMarkDone.Enabled = $false
    $form.Controls.Add($chkMarkDone)

    # 3. What did you accomplish?
    $lblAcc = New-Object System.Windows.Forms.Label
    $lblAcc.Text = "What did you accomplish?"
    $lblAcc.Location = New-Object System.Drawing.Point(10, 85)
    $lblAcc.AutoSize = $true
    $form.Controls.Add($lblAcc)
    
    $txtAcc = New-Object System.Windows.Forms.TextBox
    $txtAcc.Location = New-Object System.Drawing.Point(10, 105)
    $txtAcc.Size = New-Object System.Drawing.Size(390, 20)
    $form.Controls.Add($txtAcc)

    # 4. Plan to focus on next Key Result
    $lblNextKr = New-Object System.Windows.Forms.Label
    $lblNextKr.Text = "Plan to focus on next Key Result:"
    $lblNextKr.Location = New-Object System.Drawing.Point(10, 135)
    $lblNextKr.AutoSize = $true
    $form.Controls.Add($lblNextKr)

    $cmbNextKr = New-Object System.Windows.Forms.ComboBox
    $cmbNextKr.Location = New-Object System.Drawing.Point(10, 155)
    $cmbNextKr.Size = New-Object System.Drawing.Size(390, 20)
    $cmbNextKr.DropDownStyle = 'DropDownList'
    
    $loadNextCmbKrs = {
        $cmbNextKr.Items.Clear()
        
        $excludeKrId = ""
        if ($chkMarkDone.Checked -and $cmbKr.SelectedIndex -ge 0) {
            if ($cmbKr.SelectedItem.ToString() -match "\[(.*?)\]") {
                $excludeKrId = $matches[1]
            }
        }

        $krs = Get-TodayKeyResults -IncludeCompleted $false
        foreach ($kr in $krs) {
            if ($excludeKrId -and $kr.KeyResultID -eq $excludeKrId) { continue }
            $cmbNextKr.Items.Add("[$($kr.KeyResultID)] $($kr.Description)") | Out-Null
        }
        $cmbNextKr.Items.Add("[None] Unplanned / Distraction") | Out-Null
        
        # Default selection
        if ($global:currentKrId -and $global:currentKrId -ne $excludeKrId) {
            $matchedIdx = -1
            for ($i = 0; $i -lt $cmbNextKr.Items.Count; $i++) {
                if ($cmbNextKr.Items[$i] -match "\[$($global:currentKrId)\]") {
                    $matchedIdx = $i
                    break
                }
            }
            if ($matchedIdx -ge 0) {
                $cmbNextKr.SelectedIndex = $matchedIdx
                return
            }
        }
        if ($cmbNextKr.Items.Count -gt 0) {
            $cmbNextKr.SelectedIndex = 0
        }
    }
    &$loadNextCmbKrs
    $form.Controls.Add($cmbNextKr)

    # 5. What do you plan to do next?
    $lblPlan = New-Object System.Windows.Forms.Label
    $lblPlan.Text = "What do you plan to do next?"
    $lblPlan.Location = New-Object System.Drawing.Point(10, 185)
    $lblPlan.AutoSize = $true
    $form.Controls.Add($lblPlan)
    
    $txtPlan = New-Object System.Windows.Forms.TextBox
    $txtPlan.Name = "txtPlan"
    $txtPlan.Location = New-Object System.Drawing.Point(10, 205)
    $txtPlan.Size = New-Object System.Drawing.Size(390, 20)
    $form.Controls.Add($txtPlan)
    
    # 6. Continue previous task
    $chkCont = New-Object System.Windows.Forms.CheckBox
    $chkCont.Text = "Continue previous task"
    $chkCont.Location = New-Object System.Drawing.Point(10, 235)
    $chkCont.Size = New-Object System.Drawing.Size(200, 20)
    $form.Controls.Add($chkCont)

    # Buttons
    $btnEye = New-Object System.Windows.Forms.Button
    $btnEye.Text = "Eye Rest (20s)"
    $btnEye.Location = New-Object System.Drawing.Point(20, 285)
    $btnEye.Size = New-Object System.Drawing.Size(120, 40)
    $btnEye.Enabled = $false
    $form.Controls.Add($btnEye)
    
    $btnBreak = New-Object System.Windows.Forms.Button
    $btnBreak.Text = "Quick Break"
    $btnBreak.Location = New-Object System.Drawing.Point(145, 285)
    $btnBreak.Size = New-Object System.Drawing.Size(120, 40)
    $btnBreak.Enabled = $false
    $form.Controls.Add($btnBreak)

    $btnPause = New-Object System.Windows.Forms.Button
    $btnPause.Text = "Pause / Away"
    $btnPause.Location = New-Object System.Drawing.Point(270, 285)
    $btnPause.Size = New-Object System.Drawing.Size(120, 40)
    $btnPause.Enabled = $false
    $form.Controls.Add($btnPause)

    # --- Input Validation ---
    $validateInputs = {
        $hasKr   = ($chkUnplanned.Checked -or $cmbKr.SelectedIndex -ge 0)
        $hasAcc  = (-not [string]::IsNullOrWhiteSpace($txtAcc.Text))
        $hasPlan = ($chkCont.Checked -or (-not [string]::IsNullOrWhiteSpace($txtPlan.Text)))
        $valid   = ($hasKr -and $hasAcc -and $hasPlan)
        $btnEye.Enabled   = $valid
        $btnBreak.Enabled = $valid
        $btnPause.Enabled = $valid
        
        if (-not $chkUnplanned.Checked -and $cmbKr.SelectedIndex -ge 0) {
            $chkMarkDone.Enabled = $true
        } else {
            $chkMarkDone.Enabled = $false
            $chkMarkDone.Checked = $false
        }
    }

    $chkUnplanned.Add_CheckedChanged({
        $cmbKr.Enabled = -not $this.Checked
        $btnAddKr.Enabled = -not $this.Checked
        if ($this.Checked) {
            $cmbKr.SelectedIndex = -1
        }
        &$validateInputs
    })

    $cmbKr.Add_SelectedIndexChanged({
        &$validateInputs
        
        # Reload next KR list if completed KR changed
        $prevSelectedText = if ($cmbNextKr.SelectedItem) { $cmbNextKr.SelectedItem.ToString() } else { "" }
        &$loadNextCmbKrs
        if ($prevSelectedText) {
            $matchedIdx = -1
            for ($i = 0; $i -lt $cmbNextKr.Items.Count; $i++) {
                if ($cmbNextKr.Items[$i].ToString() -eq $prevSelectedText) {
                    $matchedIdx = $i
                    break
                }
            }
            if ($matchedIdx -ge 0) {
                $cmbNextKr.SelectedIndex = $matchedIdx
            } else {
                if ($cmbNextKr.Items.Count -gt 0) {
                    $cmbNextKr.SelectedIndex = 0
                }
            }
        }
    })

    $chkMarkDone.Add_CheckedChanged({
        if ($this.Checked) {
            $chkCont.Checked = $false
            $chkCont.Enabled = $false
        } else {
            $chkCont.Enabled = $true
        }

        $prevSelectedText = if ($cmbNextKr.SelectedItem) { $cmbNextKr.SelectedItem.ToString() } else { "" }
        &$loadNextCmbKrs
        if ($prevSelectedText) {
            $matchedIdx = -1
            for ($i = 0; $i -lt $cmbNextKr.Items.Count; $i++) {
                if ($cmbNextKr.Items[$i].ToString() -eq $prevSelectedText) {
                    $matchedIdx = $i
                    break
                }
            }
            if ($matchedIdx -ge 0) {
                $cmbNextKr.SelectedIndex = $matchedIdx
            } else {
                if ($cmbNextKr.Items.Count -gt 0) {
                    $cmbNextKr.SelectedIndex = 0
                }
            }
        }
        &$validateInputs
    })

    $txtAcc.Add_TextChanged({ &$validateInputs })
    $txtPlan.Add_TextChanged({ &$validateInputs })

    $txtAcc.Add_KeyDown({
        if ($_.KeyCode -eq 'Enter') {
            $_.SuppressKeyPress = $true
            $form.SelectNextControl($txtAcc, $true, $true, $true, $true) | Out-Null
        }
    })
    $cmbNextKr.Add_KeyDown({
        if ($_.KeyCode -eq 'Enter') {
            $_.SuppressKeyPress = $true
            $txtPlan.Focus() | Out-Null
        }
    })
    $txtPlan.Add_KeyDown({
        if ($_.KeyCode -eq 'Enter') {
            $_.SuppressKeyPress = $true
            if ($btnBreak.Enabled) { $btnBreak.Focus() | Out-Null }
            elseif ($btnEye.Enabled) { $btnEye.Focus() | Out-Null }
        }
    })

    $chkCont.Add_CheckedChanged({
            $targetTxt = $this.Parent.Controls.Find("txtPlan", $false)[0]
            if ($this.Checked) {
                $targetTxt.Enabled = $false
                $targetTxt.Text = "Continuing previous task"
                if ($cmbKr.SelectedIndex -ge 0) {
                    $krIdToMatch = ""
                    if ($cmbKr.SelectedItem.ToString() -match "\[(.*?)\]") {
                        $krIdToMatch = $matches[1]
                    }
                    if ($krIdToMatch) {
                        for ($i = 0; $i -lt $cmbNextKr.Items.Count; $i++) {
                            if ($cmbNextKr.Items[$i] -match "\[$krIdToMatch\]") {
                                $cmbNextKr.SelectedIndex = $i
                                break
                            }
                        }
                    }
                }
            }
            else {
                $targetTxt.Enabled = $true
                $targetTxt.Text = ""
            }
            &$validateInputs
        })

    # --- Block Alt+F4 and programmatic close ---
    $global:isValidSubmit = $false

    $form.Add_FormClosing({
            if ($global:isValidSubmit -ne $true) {
                $_.Cancel = $true
            }
        })

    # --- Active Presence Detection (fires every 2s; nudges user if actively working in another window) ---
    $presenceTimer = New-Object System.Windows.Forms.Timer
    $presenceTimer.Interval = 2000
    $presenceTimer.Add_Tick({
            if ($form.ContainsFocus) { return }

            $lii = New-Object Win32+LASTINPUTINFO
            $lii.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($lii)
            if ([Win32]::GetLastInputInfo([ref]$lii)) {
                $idleMs = [Environment]::TickCount - $lii.dwTime
                # Only interrupt if the user has been active (mouse/keyboard) in the last 2.5 seconds
                if ($idleMs -lt 2500) {
                    # Recenter on primary screen
                    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
                    $form.Location = New-Object System.Drawing.Point(
                        [int](($screen.Width  - $form.Width)  / 2),
                        [int](($screen.Height - $form.Height) / 2)
                    )
                    # Minimize then restore
                    $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
                    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
                    $form.TopMost = $true
                    $form.Activate()
                    [System.Media.SystemSounds]::Beep.Play()
                    
                    $fwi = New-Object Win32+FLASHWINFO
                    $fwi.cbSize    = [System.Runtime.InteropServices.Marshal]::SizeOf($fwi)
                    $fwi.hwnd      = $form.Handle
                    $fwi.dwFlags   = [Win32]::FLASHW_ALL -bor [Win32]::FLASHW_TIMER
                    $fwi.uCount    = 5
                    $fwi.dwTimeout = 0
                    [Win32]::FlashWindowEx([ref]$fwi) | Out-Null
                }
            }
        })
    $presenceTimer.Start()

    $form.Add_FormClosed({
            $presenceTimer.Stop()
            $presenceTimer.Dispose()
        })

    $btnEye.Add_Click({
            $global:isValidSubmit = $true
            $presenceTimer.Stop()
            $form.DialogResult = [System.Windows.Forms.DialogResult]::Yes
        })

    $btnBreak.Add_Click({
            $global:isValidSubmit = $true
            $presenceTimer.Stop()
            $form.DialogResult = [System.Windows.Forms.DialogResult]::No
        })

    $btnPause.Add_Click({
            $global:isValidSubmit = $true
            $presenceTimer.Stop()
            $form.DialogResult = [System.Windows.Forms.DialogResult]::Abort
        })

    $result = $form.ShowDialog()
    $logDur = ([DateTime]::Now - $formStart).TotalSeconds
    
    $action = 'QuickBreak'
    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) { $action = 'EyeRest' }
    elseif ($result -eq [System.Windows.Forms.DialogResult]::Abort) { $action = 'Pause' }

    $selectedKrId = ""
    $selectedGlobalId = ""
    if (-not $chkUnplanned.Checked -and $cmbKr.SelectedItem) {
        if ($cmbKr.SelectedItem.ToString() -match "\[(.*?)\]") {
            $selectedKrId = $matches[1]
            $todayKrs = Get-TodayKeyResults -IncludeCompleted $true
            $matched = $todayKrs | Where-Object { $_.KeyResultID -eq $selectedKrId }
            if ($matched) {
                $selectedGlobalId = $matched.GlobalID
            }
        }
    }

    $nextKrId = ""
    $nextGlobalId = ""
    if ($cmbNextKr.SelectedItem -and $cmbNextKr.SelectedItem.ToString() -ne "[None] Unplanned / Distraction") {
        if ($cmbNextKr.SelectedItem.ToString() -match "\[(.*?)\]") {
            $nextKrId = $matches[1]
            $todayKrs = Get-TodayKeyResults -IncludeCompleted $true
            $matched = $todayKrs | Where-Object { $_.KeyResultID -eq $nextKrId }
            if ($matched) {
                $nextGlobalId = $matched.GlobalID
            }
        }
    }

    return @{
        Action          = $action
        Accomplished    = $txtAcc.Text
        Planned         = $txtPlan.Text
        LogDuration     = $logDur
        KeyResultID     = $selectedKrId
        GlobalID        = $selectedGlobalId
        IsDistraction   = $chkUnplanned.Checked
        MarkDone        = $chkMarkDone.Checked
        NextKeyResultID = $nextKrId
        NextGlobalID    = $nextGlobalId
    }
}

function Show-ReturnForm($idleMinutes, $isQuickBreak) {
    $formStart = [DateTime]::Now
    $form = New-Object System.Windows.Forms.Form
    if ($isQuickBreak) {
        $form.Text = "Quick Break Over - Welcome Back!"
    } else {
        $form.Text = "Welcome Back - Away Period Logged"
    }
    $form.Size = New-Object System.Drawing.Size(300, 260)
    $form.StartPosition = "CenterScreen"
    $form.TopMost = $true
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    
    $lblPlan = New-Object System.Windows.Forms.Label
    $lblPlan.Text = "You planned to work on next:`n$($global:lastPlannedTask)"
    $lblPlan.Location = New-Object System.Drawing.Point(10, 10)
    $lblPlan.Size = New-Object System.Drawing.Size(260, 35)
    $form.Controls.Add($lblPlan)

    $lbl = New-Object System.Windows.Forms.Label
    if ($isQuickBreak) {
        $lbl.Text = "Break logged. What were you doing?"
    } else {
        $lbl.Text = "Away for $([math]::Round($idleMinutes)) min. What were you doing?"
    }
    $lbl.Location = New-Object System.Drawing.Point(10, 50)
    $lbl.Size = New-Object System.Drawing.Size(260, 20)
    $form.Controls.Add($lbl)
    
    $cmb = New-Object System.Windows.Forms.ComboBox
    $cmb.Items.AddRange($global:awayReasons)
    $cmb.SelectedIndex = 0
    $cmb.Location = New-Object System.Drawing.Point(10, 75)
    $cmb.Size = New-Object System.Drawing.Size(260, 20)
    $cmb.DropDownStyle = 'DropDownList'
    $form.Controls.Add($cmb)

    $lblNotes = New-Object System.Windows.Forms.Label
    $lblNotes.Text = "Notes:"
    $lblNotes.Location = New-Object System.Drawing.Point(10, 105)
    $lblNotes.AutoSize = $true
    $form.Controls.Add($lblNotes)

    $txtNotes = New-Object System.Windows.Forms.TextBox
    $txtNotes.Location = New-Object System.Drawing.Point(10, 125)
    $txtNotes.Size = New-Object System.Drawing.Size(260, 20)
    $form.Controls.Add($txtNotes)
    
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = "Log and Resume"
    $btn.Location = New-Object System.Drawing.Point(80, 165)
    $btn.Size = New-Object System.Drawing.Size(120, 30)
    $btn.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btn)
    $form.AcceptButton = $btn
    
    $form.ShowDialog() | Out-Null
    $logDur = ([DateTime]::Now - $formStart).TotalSeconds

    return @{ Reason = $cmb.SelectedItem.ToString(); Notes = $txtNotes.Text; LogDuration = $logDur }
}

function Show-QuickBreakForm {
    $formStart = [DateTime]::Now
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Quick Break Type"
    $form.Size = New-Object System.Drawing.Size(250, 150)
    $form.StartPosition = "CenterScreen"
    $form.TopMost = $true
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $cmb = New-Object System.Windows.Forms.ComboBox
    $cmb.Items.AddRange($global:quickBreakReasons)
    $cmb.SelectedIndex = 0
    $cmb.Location = New-Object System.Drawing.Point(20, 20)
    $cmb.Size = New-Object System.Drawing.Size(190, 20)
    $cmb.DropDownStyle = 'DropDownList'
    $form.Controls.Add($cmb)

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = "Go"
    $btn.Location = New-Object System.Drawing.Point(65, 60)
    $btn.Size = New-Object System.Drawing.Size(100, 30)
    $btn.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btn)
    $form.AcceptButton = $btn

    $form.ShowDialog() | Out-Null
    $logDur = ([DateTime]::Now - $formStart).TotalSeconds

    return @{ Type = $cmb.SelectedItem.ToString(); LogDuration = $logDur }
}

# --- System Tray Icon ---
$components = New-Object System.ComponentModel.Container
$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip($components)

$itemKrs = $contextMenu.Items.Add("Manage Key Results...")
$itemKrs.Add_Click({ Show-KeyResultsForm })

$itemPause = $contextMenu.Items.Add("Pause / Log Break")
$itemPause.Add_Click({ $global:manualInterrupt = $true })

$itemExit = $contextMenu.Items.Add("Exit")
$itemExit.Add_Click({
        Write-Log "System" "Exit" 0 "" "" "Manual tray exit" 0 (Get-ScheduleContext) ""
        $trayIcon.Visible = $false
        $trayIcon.Dispose()
        [System.Environment]::Exit(0)
    })

$trayIcon = New-Object System.Windows.Forms.NotifyIcon($components)
$trayIcon.Icon = [System.Drawing.SystemIcons]::Information
$trayIcon.ContextMenuStrip = $contextMenu
$trayIcon.Text = "Apoena"
$trayIcon.Visible = $true

# --- Main Loop ---
Write-Log "System" "Started" 0 "" "" "" 0 (Get-ScheduleContext) ""

$global:currentKrId = ""
$global:currentGlobalId = ""
$global:lastPlannedTask = ""

if ($isSameDayRestart) {
    $resumed = Show-ResumedSessionForm
    $global:currentKrId = $resumed.KeyResultID
    $global:currentGlobalId = $resumed.GlobalID
    $global:lastPlannedTask = $resumed.Planned
    Write-Log "System" "Resumed" 0 "" "" $resumed.Context $resumed.LogDuration (Get-ScheduleContext) $resumed.KeyResultID $null $false $resumed.GlobalID
    $focusSessionTimeStr = Get-FormattedDuration $focusSessionDuration
    [System.Windows.Forms.MessageBox]::Show("Your next focus session has started! It will last for $focusSessionTimeStr.", "Focus Session Started", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}
else {
    $todayKrs = Get-TodayKeyResults -IncludeCompleted $true
    if ($todayKrs.Count -eq 0) {
        Show-KeyResultsForm
        $todayKrs = Get-TodayKeyResults -IncludeCompleted $true
        if ($todayKrs.Count -eq 0) {
            Write-Log "System" "Exit" 0 "" "" "Closed planning form on startup without key results" 0 (Get-ScheduleContext) ""
            if ($trayIcon) {
                $trayIcon.Visible = $false
                $trayIcon.Dispose()
            }
            [System.Environment]::Exit(0)
        }
    }

    $start = Show-StartSessionForm
    $global:currentKrId = $start.KeyResultID
    $global:currentGlobalId = $start.GlobalID
    $global:lastPlannedTask = $start.Planned

    $focusSessionTimeStr = Get-FormattedDuration $focusSessionDuration
    [System.Windows.Forms.MessageBox]::Show("Welcome to Apoena! Have a great day at work.`n`nI'll monitor your routine and remind you to take breaks. Your first focus session has started and will last for $focusSessionTimeStr.", "Apoena Started", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

while ($true) {
    [System.Windows.Forms.Application]::DoEvents()
    
    # Update Tray Icon Tooltip with remaining time
    $elapsedSecs = ([DateTime]::Now - $lastBreak).TotalSeconds
    $remainingSecs = [math]::Max(0, $focusSessionDuration - $elapsedSecs)
    $ts = [TimeSpan]::FromSeconds($remainingSecs)
    $timeStr = if ($ts.TotalHours -ge 1) { $ts.ToString('hh\:mm\:ss') } else { $ts.ToString('mm\:ss') }
    
    $krInfo = ""
    if ($global:currentKrId) {
        $map = Get-AllKeyResultsMap
        $kr = $map[$global:currentGlobalId]
        if ($kr) {
            $krInfo = "`nFocus: [$($global:currentKrId)] $($kr.Description)"
        }
    } else {
        $krInfo = "`nFocus: Unplanned / Distraction"
    }

    $tooltipText = "Apoena - $timeStr remaining$krInfo"
    if ($tooltipText.Length -gt 63) {
        $tooltipText = $tooltipText.Substring(0, 60) + "..."
    }
    $trayIcon.Text = $tooltipText

    $lii = New-Object Win32+LASTINPUTINFO
    $lii.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($lii)
    
    # 1. Check for manual tray interruption
    if ($global:manualInterrupt) {
        $workedSecs = ([DateTime]::Now - $focusSessionStart).TotalSeconds
        Write-Log "Focus Session" "Partial (Manual Pause)" $workedSecs "Interrupted" "Manual Pause" "" 0 (Get-ScheduleContext) $global:currentKrId $null $false $global:currentGlobalId
        
        $pauseStart = [DateTime]::Now
        Invoke-EnforcedBreak -durationSecs $pauseMinDuration -context "Pause"
        
        $awaySecs = ([DateTime]::Now - $pauseStart).TotalSeconds
        $rtn = Show-ReturnForm ($awaySecs / 60) $false
        Write-Log "Away" $rtn.Reason $awaySecs "" "" $rtn.Notes $rtn.LogDuration (Get-ScheduleContext) ""
        Invoke-EndOfDay $rtn.Reason
        
        $lastBreak = [DateTime]::Now
        $focusSessionStart = [DateTime]::Now
        $global:manualInterrupt = $false
    }
    
    # 2. Smart Idle Detection (15+ minutes)
    if ([Win32]::GetLastInputInfo([ref]$lii)) {
        $idleSeconds = ([Environment]::TickCount - $lii.dwTime) / 1000
        if ($idleSeconds -ge $idleThreshold) {
            $awayStart = [DateTime]::Now.AddSeconds(-$idleSeconds)
            $workedSecs = ($awayStart - $focusSessionStart).TotalSeconds
            
            Write-Log "Focus Session" "Partial (Idle Detected)" $workedSecs "Auto-detected idle" "" "" 0 (Get-ScheduleContext) $global:currentKrId $null $false $global:currentGlobalId
            [System.Windows.Forms.MessageBox]::Show("You've been idle for over 15 minutes. Monitoring paused until you click OK.", "Idle Detected", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            
            $actualAwaySecs = ([DateTime]::Now - $awayStart).TotalSeconds
            $rtn = Show-ReturnForm ($actualAwaySecs / 60) $false
            Write-Log "Away" $rtn.Reason $actualAwaySecs "" "" $rtn.Notes $rtn.LogDuration (Get-ScheduleContext) ""
            Invoke-EndOfDay $rtn.Reason
            
            $lastBreak = [DateTime]::Now
            $focusSessionStart = [DateTime]::Now
        }
    }

    # 3. Standard interval check
    if (([DateTime]::Now - $lastBreak).TotalSeconds -ge $focusSessionDuration) {
        $workedSecs = ([DateTime]::Now - $focusSessionStart).TotalSeconds
        $result = Show-FocusSessionForm
        Write-Log "Focus Session" "Complete" $workedSecs $result.Accomplished $result.Planned "" $result.LogDuration (Get-ScheduleContext) $result.KeyResultID $null $result.IsDistraction $result.GlobalID
        
        if ($result.MarkDone -and $result.GlobalID) {
            $map = Get-AllKeyResultsMap
            $kr = $map[$result.GlobalID]
            if ($kr) {
                Add-KeyResult $kr.Category $kr.Description $result.GlobalID "Done" | Out-Null
            }
        }

        $global:currentKrId = $result.NextKeyResultID
        $global:currentGlobalId = $result.NextGlobalID
        $global:lastPlannedTask = $result.Planned
        
        if ($result.Action -eq 'Pause') {
            $pauseStart = [DateTime]::Now
            Invoke-EnforcedBreak -durationSecs $pauseMinDuration -context "Pause"
            
            $awaySecs = ([DateTime]::Now - $pauseStart).TotalSeconds
            $rtn = Show-ReturnForm ($awaySecs / 60) $false
            Write-Log "Away" $rtn.Reason $awaySecs "" "" $rtn.Notes $rtn.LogDuration (Get-ScheduleContext) ""
            Invoke-EndOfDay $rtn.Reason
            
        }
        elseif ($result.Action -eq 'EyeRest') {
            [System.Windows.Forms.MessageBox]::Show("Look 20 feet away! Click OK, then DO NOT touch the mouse or keyboard.", "Eye Rest", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            Start-Sleep -Seconds 2
            $restCompleted = $false
            
            while (-not $restCompleted) {
                $interrupted = $false
                for ($i = 0; $i -lt $breakDuration; $i++) {
                    Start-Sleep -Seconds 1
                    [System.Windows.Forms.Application]::DoEvents()
                    if ([Win32]::GetLastInputInfo([ref]$lii)) {
                        if ((([Environment]::TickCount - $lii.dwTime) / 1000) -lt 1) {
                            $interrupted = $true
                            break
                        }
                    }
                }
                
                if ($interrupted) {
                    $retry = [System.Windows.Forms.MessageBox]::Show("You moved! Restart the 20-second break (Yes), or take a physical break instead (No)?", "Warning", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
                    if ($retry -eq [System.Windows.Forms.DialogResult]::No) {
                        $qbResult = Show-QuickBreakForm
                        $breakStart = [DateTime]::Now
                        Invoke-EnforcedBreak -durationSecs $quickBreakMinDuration -context "Break"
                        $awaySecs = ([DateTime]::Now - $breakStart).TotalSeconds
                        $rtn = Show-ReturnForm ($awaySecs / 60) $true
                        Write-Log "Quick Break" $qbResult.Type $awaySecs "" "" $rtn.Notes ($rtn.LogDuration + $qbResult.LogDuration) (Get-ScheduleContext) ""
                        $restCompleted = $true
                    }
                    else {
                        Start-Sleep -Seconds 2
                    }
                }
                else {
                    $endTime = [DateTime]::Now.ToString("HH:mm:ss")
                    [System.Windows.Forms.MessageBox]::Show("Rest complete at $endTime! Click OK to resume.", "Break Over", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
                    $restCompleted = $true
                    Write-Log "Eye Rest" "Complete" $breakDuration "" "" "" 0 (Get-ScheduleContext) ""
                }
            }
        }
        else {
            $qbResult = Show-QuickBreakForm
            $breakStart = [DateTime]::Now
            Invoke-EnforcedBreak -durationSecs $quickBreakMinDuration -context "Break"
            $awaySecs = ([DateTime]::Now - $breakStart).TotalSeconds
            $rtn = Show-ReturnForm ($awaySecs / 60) $true
            Write-Log "Quick Break" $qbResult.Type $awaySecs "" "" $rtn.Notes ($rtn.LogDuration + $qbResult.LogDuration) (Get-ScheduleContext) ""
        }
        
        $lastBreak = [DateTime]::Now
        $focusSessionStart = [DateTime]::Now
    }
    Start-Sleep -Milliseconds 1000
}
