#Requires -Version 5.1
# Apoena - 20-20-20 Eye Rest & Work Block Logger
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
}
"@

# --- Single Instance Guard ---
$createdNew = $false
$global:mutex = New-Object System.Threading.Mutex($true, "Global\ApoenaEyeRestMutex", [ref]$createdNew)
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

$workBlockDuration = if ($config.WorkBlockMinutes) { $config.WorkBlockMinutes * 60 } else { 20 * 60 }   # default: 20 minutes
$breakDuration = if ($config.BreakDurationSeconds) { $config.BreakDurationSeconds } else { 20 }     # default: 20 seconds
$idleThreshold = if ($config.IdleThresholdMinutes) { $config.IdleThresholdMinutes * 60 } else { 15 * 60 } # default: 15 minutes
$awayReasons = if ($config.AwayReasons) { $config.AwayReasons } else { @("Meeting", "Lunch", "Call", "Offline Work", "Coffee", "Rest", "Distraction", "End of Day", "Other") }
$quickBreakReasons = if ($config.QuickBreakReasons) { $config.QuickBreakReasons } else { @("Pee", "Poo", "Water", "Coffee", "Snack", "Stretch", "Other") }
$logFile = Join-Path $scriptDir "apoena-log.csv"

$global:manualInterrupt = $false
$global:blockIndex = 0
$global:daySequence = 0
$global:lastLogDate = (Get-Date).Date
$lastBreak = [DateTime]::Now
$workBlockStart = [DateTime]::Now

# --- Helper Functions ---
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

function Write-Log($eventCategory, $eventDetail, $durationSecs, $accomplished, $planned, $notes, $logDurSecs, $context) {
    # Reset day sequence at midnight
    $today = (Get-Date).Date
    if ($today -ne $global:lastLogDate) {
        $global:daySequence = 0
        $global:lastLogDate = $today
    }

    $global:blockIndex++
    $global:daySequence++

    $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
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
        $global:blockIndex.ToString([System.Globalization.CultureInfo]::InvariantCulture),
        $global:daySequence.ToString([System.Globalization.CultureInfo]::InvariantCulture),
        $duration,
        $safeAccomplished,
        $safePlanned,
        $safeNotes,
        $logDur,
        $safeContext
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
        $suffix = if ($mins -ne 1) { "s" } else { "" }
        return "$mins minute$suffix"
    }
    else {
        $suffix = if ($seconds -ne 1) { "s" } else { "" }
        return "$seconds second$suffix"
    }
}

# --- Initialization, Crash Detection & Same-Day Restart ---
$isSameDayRestart = $false
if (-not (Test-Path $logFile)) {
    "Timestamp,TimezoneOffset,EventCategory,EventDetail,BlockIndex,DaySequence,DurationSeconds,Accomplished,Planned,Notes,LoggingDurationSecs,ScheduleContext" | Out-File $logFile -Encoding UTF8
}
else {
    $lastLine = Get-Content $logFile -Tail 1
    if ($lastLine -match ',') {
        $parts = $lastLine -split ','

        # Detect same-day restart and restore counters
        $lastTimestamp = $parts[0]
        try {
            $lastDate = [datetime]::ParseExact($lastTimestamp, "yyyy-MM-dd HH:mm:ss", $null).Date
            if ($lastDate -eq (Get-Date).Date) {
                $isSameDayRestart = $true
                $global:blockIndex = [int]$parts[4]
                $global:daySequence = [int]$parts[5]
            }
        } catch { }

        # Crash detection
        $lastEvent = $parts[2].Trim('"')
        if ($lastEvent -notmatch 'System') {
            # Previous session did not exit cleanly
        }
        else {
            $lastDetail = $parts[3].Trim('"')
            if ($lastDetail -notmatch 'Exit') {
                Write-Log "System" "Unexpected Exit" 0 "" "" "Detected on startup" 0 (Get-ScheduleContext)
            }
        }
    }
}

# --- UI Forms ---
function Show-ResumedSessionForm {
    $formStart = [DateTime]::Now
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Welcome Back"
    $form.Size = New-Object System.Drawing.Size(380, 200)
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
    $txtContext.Location = New-Object System.Drawing.Point(10, 50)
    $txtContext.Size = New-Object System.Drawing.Size(340, 20)
    $form.Controls.Add($txtContext)

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = "Resume"
    $btn.Location = New-Object System.Drawing.Point(130, 100)
    $btn.Size = New-Object System.Drawing.Size(100, 30)
    $btn.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btn)

    $form.ShowDialog() | Out-Null
    $logDur = ([DateTime]::Now - $formStart).TotalSeconds
    return @{ Context = $txtContext.Text; LogDuration = $logDur }
}

function Show-WorkBlockForm {
    $formStart = [DateTime]::Now
    $form = New-Object System.Windows.Forms.Form
    $blockTimeStr = Get-FormattedDuration $workBlockDuration
    $form.Text = "Work Block Complete! ($blockTimeStr)"
    $form.Size = New-Object System.Drawing.Size(430, 260)
    $form.StartPosition = "CenterScreen"
    $form.TopMost = $true
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    
    $lblAcc = New-Object System.Windows.Forms.Label
    $lblAcc.Text = "What did you accomplish?"
    $lblAcc.Location = New-Object System.Drawing.Point(10, 10)
    $lblAcc.AutoSize = $true
    $form.Controls.Add($lblAcc)
    
    $txtAcc = New-Object System.Windows.Forms.TextBox
    $txtAcc.Location = New-Object System.Drawing.Point(10, 30)
    $txtAcc.Size = New-Object System.Drawing.Size(390, 20)
    $form.Controls.Add($txtAcc)
    
    $lblPlan = New-Object System.Windows.Forms.Label
    $lblPlan.Text = "What do you plan to do next?"
    $lblPlan.Location = New-Object System.Drawing.Point(10, 60)
    $lblPlan.AutoSize = $true
    $form.Controls.Add($lblPlan)
    
    $txtPlan = New-Object System.Windows.Forms.TextBox
    $txtPlan.Name = "txtPlan"
    $txtPlan.Location = New-Object System.Drawing.Point(10, 80)
    $txtPlan.Size = New-Object System.Drawing.Size(390, 20)
    $form.Controls.Add($txtPlan)
    
    $chkCont = New-Object System.Windows.Forms.CheckBox
    $chkCont.Text = "Continue previous task"
    $chkCont.Location = New-Object System.Drawing.Point(10, 110)
    $chkCont.Size = New-Object System.Drawing.Size(200, 20)
    $chkCont.Add_CheckedChanged({
            $targetTxt = $this.Parent.Controls.Find("txtPlan", $false)[0]
            if ($this.Checked) {
                $targetTxt.Enabled = $false
                $targetTxt.Text = "Continuing previous task"
            }
            else {
                $targetTxt.Enabled = $true
                $targetTxt.Text = ""
            }
        })
    $form.Controls.Add($chkCont)
    
    $btnEye = New-Object System.Windows.Forms.Button
    $btnEye.Text = "Eye Rest (20s)"
    $btnEye.Location = New-Object System.Drawing.Point(20, 160)
    $btnEye.Size = New-Object System.Drawing.Size(120, 40)
    $btnEye.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    $form.Controls.Add($btnEye)
    
    $btnBreak = New-Object System.Windows.Forms.Button
    $btnBreak.Text = "Quick Break"
    $btnBreak.Location = New-Object System.Drawing.Point(145, 160)
    $btnBreak.Size = New-Object System.Drawing.Size(120, 40)
    $btnBreak.DialogResult = [System.Windows.Forms.DialogResult]::No
    $form.Controls.Add($btnBreak)

    $btnPause = New-Object System.Windows.Forms.Button
    $btnPause.Text = "Pause / Away"
    $btnPause.Location = New-Object System.Drawing.Point(270, 160)
    $btnPause.Size = New-Object System.Drawing.Size(120, 40)
    $btnPause.DialogResult = [System.Windows.Forms.DialogResult]::Abort
    $form.Controls.Add($btnPause)
    
    $result = $form.ShowDialog()
    $logDur = ([DateTime]::Now - $formStart).TotalSeconds
    
    $action = 'QuickBreak'
    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) { $action = 'EyeRest' }
    elseif ($result -eq [System.Windows.Forms.DialogResult]::Abort) { $action = 'Pause' }

    return @{
        Action       = $action
        Accomplished = $txtAcc.Text
        Planned      = $txtPlan.Text
        LogDuration  = $logDur
    }
}

function Show-ReturnForm($idleMinutes) {
    $formStart = [DateTime]::Now
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Welcome Back"
    $form.Size = New-Object System.Drawing.Size(300, 220)
    $form.StartPosition = "CenterScreen"
    $form.TopMost = $true
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Away for $([math]::Round($idleMinutes)) min. What were you doing?"
    $lbl.Location = New-Object System.Drawing.Point(10, 10)
    $lbl.Size = New-Object System.Drawing.Size(260, 20)
    $form.Controls.Add($lbl)
    
    $cmb = New-Object System.Windows.Forms.ComboBox
    $cmb.Items.AddRange($global:awayReasons)
    $cmb.SelectedIndex = 0
    $cmb.Location = New-Object System.Drawing.Point(10, 40)
    $cmb.Size = New-Object System.Drawing.Size(260, 20)
    $cmb.DropDownStyle = 'DropDownList'
    $form.Controls.Add($cmb)

    $lblNotes = New-Object System.Windows.Forms.Label
    $lblNotes.Text = "Notes:"
    $lblNotes.Location = New-Object System.Drawing.Point(10, 70)
    $lblNotes.AutoSize = $true
    $form.Controls.Add($lblNotes)

    $txtNotes = New-Object System.Windows.Forms.TextBox
    $txtNotes.Location = New-Object System.Drawing.Point(10, 90)
    $txtNotes.Size = New-Object System.Drawing.Size(260, 20)
    $form.Controls.Add($txtNotes)
    
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = "Log and Resume"
    $btn.Location = New-Object System.Drawing.Point(80, 130)
    $btn.Size = New-Object System.Drawing.Size(120, 30)
    $btn.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btn)
    
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

    $form.ShowDialog() | Out-Null
    $logDur = ([DateTime]::Now - $formStart).TotalSeconds

    return @{ Type = $cmb.SelectedItem.ToString(); LogDuration = $logDur }
}

# --- System Tray Icon ---
$components = New-Object System.ComponentModel.Container
$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip($components)

$itemPause = $contextMenu.Items.Add("Pause / Log Break")
$itemPause.Add_Click({ $global:manualInterrupt = $true })

$itemExit = $contextMenu.Items.Add("Exit")
$itemExit.Add_Click({
        Write-Log "System" "Exit" 0 "" "" "Manual tray exit" 0 (Get-ScheduleContext)
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
Write-Log "System" "Started" 0 "" "" "" 0 (Get-ScheduleContext)

if ($isSameDayRestart) {
    $resumed = Show-ResumedSessionForm
    Write-Log "System" "Resumed" 0 "" "" $resumed.Context $resumed.LogDuration (Get-ScheduleContext)
    $blockTimeStr = Get-FormattedDuration $workBlockDuration
    [System.Windows.Forms.MessageBox]::Show("Your next work block has started! It will last for $blockTimeStr.", "Work Block Started", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
} else {
    [System.Windows.Forms.MessageBox]::Show("Welcome to Apoena! Have a great day at work. I'll monitor your routine and remind you to take breaks.", "Apoena Started", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    $blockTimeStr = Get-FormattedDuration $workBlockDuration
    [System.Windows.Forms.MessageBox]::Show("Your first work block has started! It will last for $blockTimeStr.", "Work Block Started", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

while ($true) {
    [System.Windows.Forms.Application]::DoEvents()
    
    # Update Tray Icon Tooltip with remaining time
    $elapsedSecs = ([DateTime]::Now - $lastBreak).TotalSeconds
    $remainingSecs = [math]::Max(0, $workBlockDuration - $elapsedSecs)
    $ts = [TimeSpan]::FromSeconds($remainingSecs)
    $timeStr = if ($ts.TotalHours -ge 1) { $ts.ToString('hh\:mm\:ss') } else { $ts.ToString('mm\:ss') }
    $trayIcon.Text = "Apoena - $timeStr remaining"

    $lii = New-Object Win32+LASTINPUTINFO
    $lii.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($lii)
    
    # 1. Check for manual tray interruption
    if ($global:manualInterrupt) {
        $workedSecs = ([DateTime]::Now - $workBlockStart).TotalSeconds
        Write-Log "Work Block" "Partial (Manual Pause)" $workedSecs "Interrupted" "Manual Pause" "" 0 (Get-ScheduleContext)
        
        $pauseStart = [DateTime]::Now
        [System.Windows.Forms.MessageBox]::Show("Monitoring paused. Click OK when you return to your desk.", "Paused", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        
        $awaySecs = ([DateTime]::Now - $pauseStart).TotalSeconds
        $rtn = Show-ReturnForm ($awaySecs / 60)
        Write-Log "Away" $rtn.Reason $awaySecs "" "" $rtn.Notes $rtn.LogDuration (Get-ScheduleContext)
        Invoke-EndOfDay $rtn.Reason
        
        $lastBreak = [DateTime]::Now
        $workBlockStart = [DateTime]::Now
        $global:manualInterrupt = $false
    }
    
    # 2. Smart Idle Detection (15+ minutes)
    if ([Win32]::GetLastInputInfo([ref]$lii)) {
        $idleSeconds = ([Environment]::TickCount - $lii.dwTime) / 1000
        if ($idleSeconds -ge $idleThreshold) {
            $awayStart = [DateTime]::Now.AddSeconds(-$idleSeconds)
            $workedSecs = ($awayStart - $workBlockStart).TotalSeconds
            
            Write-Log "Work Block" "Partial (Idle Detected)" $workedSecs "Auto-detected idle" "" "" 0 (Get-ScheduleContext)
            [System.Windows.Forms.MessageBox]::Show("You've been idle for over 15 minutes. Monitoring paused until you click OK.", "Idle Detected", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            
            $actualAwaySecs = ([DateTime]::Now - $awayStart).TotalSeconds
            $rtn = Show-ReturnForm ($actualAwaySecs / 60)
            Write-Log "Away" $rtn.Reason $actualAwaySecs "" "" $rtn.Notes $rtn.LogDuration (Get-ScheduleContext)
            Invoke-EndOfDay $rtn.Reason
            
            $lastBreak = [DateTime]::Now
            $workBlockStart = [DateTime]::Now
        }
    }

    # 3. Standard 20-minute interval check
    if (([DateTime]::Now - $lastBreak).TotalSeconds -ge $workBlockDuration) {
        $workedSecs = ([DateTime]::Now - $workBlockStart).TotalSeconds
        $result = Show-WorkBlockForm
        Write-Log "Work Block" "Complete" $workedSecs $result.Accomplished $result.Planned "" $result.LogDuration (Get-ScheduleContext)
        
        if ($result.Action -eq 'Pause') {
            $pauseStart = [DateTime]::Now
            [System.Windows.Forms.MessageBox]::Show("Monitoring paused. Click OK when you return to your desk.", "Paused", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            
            $awaySecs = ([DateTime]::Now - $pauseStart).TotalSeconds
            $rtn = Show-ReturnForm ($awaySecs / 60)
            Write-Log "Away" $rtn.Reason $awaySecs "" "" $rtn.Notes $rtn.LogDuration (Get-ScheduleContext)
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
                        [System.Windows.Forms.MessageBox]::Show("Take your time! Click OK when you return to your desk.", "Quick Break", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
                        Write-Log "Quick Break" $qbResult.Type ([DateTime]::Now - $breakStart).TotalSeconds "" "" "" $qbResult.LogDuration (Get-ScheduleContext)
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
                    Write-Log "Eye Rest" "Complete" $breakDuration "" "" "" 0 (Get-ScheduleContext)
                }
            }
        }
        else {
            $qbResult = Show-QuickBreakForm
            $breakStart = [DateTime]::Now
            [System.Windows.Forms.MessageBox]::Show("Take your time! Click OK when you return to your desk.", "Quick Break", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            Write-Log "Quick Break" $qbResult.Type ([DateTime]::Now - $breakStart).TotalSeconds "" "" "" $qbResult.LogDuration (Get-ScheduleContext)
        }
        
        $lastBreak = [DateTime]::Now
        $workBlockStart = [DateTime]::Now
    }
    Start-Sleep -Milliseconds 1000
}
