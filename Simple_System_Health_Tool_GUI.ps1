#Requires -Version 5.1
<#
.SYNOPSIS    Simple System Health Tool - GUI Edition  v3.1
.DESCRIPTION Graphical interface for common Windows maintenance tasks.
             Self-elevates to Administrator if needed.
             No compiled executables, no encoded commands.
#>

# Catch any startup crash and show it in a popup instead of a vanishing console
trap {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show(
            "Startup error:`n`n$($_.Exception.Message)`n`n$($_.InvocationInfo.PositionMessage)",
            "Simple System Health Tool - Error", "OK", "Error") | Out-Null
    } catch {
        Write-Host "FATAL: $($_.Exception.Message)" -ForegroundColor Red
    }
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# ==============================================================================
# SELF-ELEVATE
# ==============================================================================
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $psPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Definition }
    Start-Process powershell.exe `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$psPath`"" `
        -Verb RunAs `
        -WindowStyle Hidden
    exit 0
}

# ==============================================================================
# PATHS
# ==============================================================================
$ScriptDir  = if ($PSScriptRoot -and $PSScriptRoot -ne '') {
    $PSScriptRoot
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Definition
}
if (-not $ScriptDir -or -not (Test-Path $ScriptDir)) { $ScriptDir = $env:TEMP }
$ReportPath = Join-Path $ScriptDir "$($env:COMPUTERNAME)SystemHealth.txt"

# ==============================================================================
# INTER-THREAD MESSAGE QUEUE
# Message format: single-char type + "|" + text
#   H=header (cyan)  P=pass (green)  F=fail (red)  E=error (red)
#   D=detail (dim)   I=info (white)
# ==============================================================================
$script:MsgQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:IsBusy   = $false
$script:PSInst   = $null
$script:RS       = $null
$script:Handle   = $null

# ==============================================================================
# REPORT  (called on UI thread only)
# ==============================================================================
function Initialize-Report {
    if (Test-Path $ReportPath) { return }
    $sep  = "=" * 79
    $rows = [System.Collections.Generic.List[string]]::new()
    $rows.Add($sep)
    $rows.Add("$($env:COMPUTERNAME) System Health Report")
    $rows.Add($sep)
    $rows.Add("Computer Name : $($env:COMPUTERNAME)")
    try {
        $reg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -EA Stop
        $rows.Add("Windows       : $($reg.ProductName)")
        $rows.Add("Version       : $($reg.DisplayVersion)")
        $rows.Add("Build         : $($reg.CurrentBuild)")
    } catch {}
    try {
        $sn = (Get-CimInstance Win32_BIOS -EA Stop).SerialNumber.Trim()
        if ($sn -and $sn -notmatch "O\.E\.M|^\s*$") { $rows.Add("Serial Number : $sn") }
    } catch {}
    try {
        $pk = (Get-CimInstance -Query "SELECT OA3xOriginalProductKey FROM SoftwareLicensingService" -EA Stop).OA3xOriginalProductKey
        if ($pk) { $rows.Add("License Key   : $pk") } else { $rows.Add("License Key   : Not found or not exposed.") }
    } catch { $rows.Add("License Key   : Not found or not exposed.") }
    $rows.Add("Created       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $rows.Add($sep)
    $rows.Add("")
    [IO.File]::WriteAllLines($ReportPath, $rows, [Text.Encoding]::UTF8)
}

# ==============================================================================
# BACKGROUND TASK SCRIPT
# Variables injected via runspace SetVariable:
#   $Queue       ConcurrentQueue[string]
#   $ReportPath  string
#   $TaskName    string
# ==============================================================================
$BackgroundScript = @'
function Write-Section([string]$Title) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    [IO.File]::AppendAllText($ReportPath,
        "`n$("-" * 79)`n[$ts] $Title`n", [Text.Encoding]::UTF8)
}
function Write-Result([string]$Result, [int]$Code, [string]$Msg) {
    [IO.File]::AppendAllText($ReportPath,
        "Result    : $Result`nExit Code : $Code`nMessage   : $Msg`n",
        [Text.Encoding]::UTF8)
}
function Invoke-Step([string]$Title, [string]$CmdLine) {
    Write-Section $Title
    $Queue.Enqueue("I|  $Title")
    try {
        $si = New-Object System.Diagnostics.ProcessStartInfo
        $si.FileName               = "cmd.exe"
        $si.Arguments              = "/c $CmdLine"
        $si.RedirectStandardOutput = $true
        $si.RedirectStandardError  = $true
        $si.UseShellExecute        = $false
        $si.CreateNoWindow         = $true

        $proc = [System.Diagnostics.Process]::Start($si)
        $out  = $proc.StandardOutput.ReadToEnd()
        $err  = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $rc   = $proc.ExitCode

        $combined = ($out + $err).Trim()
        foreach ($ln in ($combined -split "`r?`n")) {
            if ($ln.Trim()) { $Queue.Enqueue("D|    $ln") }
        }
        $last = ($combined -split "`r?`n" |
                 Where-Object { $_.Trim() } | Select-Object -Last 1)
        if (-not $last) { $last = "(no output)" }

        $res = if ($rc -eq 0) { "PASS" } else { "FAIL" }
        Write-Result $res $rc $last
        if ($rc -eq 0) { $Queue.Enqueue("P|    [PASS] Exit code: $rc") }
        else           { $Queue.Enqueue("F|    [FAIL] Exit code: $rc") }
        $Queue.Enqueue("I|")
    } catch {
        Write-Result "FAIL" -1 $_.Exception.Message
        $Queue.Enqueue("E|    [ERROR] $($_.Exception.Message)")
        $Queue.Enqueue("I|")
    }
}

switch ($TaskName) {
    "PrintSpooler" {
        $Queue.Enqueue("H|-- Reset Print Spooler ------------------------------------------------------")
        Invoke-Step "Stop Print Spooler"  "net stop spooler"
        $q = "$env:SystemRoot\System32\spool\PRINTERS"
        if (Test-Path $q) {
            Remove-Item "$q\*" -Force -ErrorAction SilentlyContinue
            $Queue.Enqueue("D|    Print queue cleared.")
        }
        Invoke-Step "Start Print Spooler" "net start spooler"
    }
    "NetworkReset" {
        $Queue.Enqueue("H|-- Reset Network -----------------------------------------------------------")
        Invoke-Step "Disable Physical Adapters" 'wmic path win32_networkadapter where "NetEnabled=true and PhysicalAdapter=true" call disable'
        Invoke-Step "Enable Physical Adapters"  'wmic path win32_networkadapter where "PhysicalAdapter=true" call enable'
        Invoke-Step "Release and Renew IP"       "ipconfig /release & ipconfig /renew"
        Invoke-Step "Flush DNS Cache"            "ipconfig /flushdns"
        Invoke-Step "Reset Winsock Catalog"      "netsh winsock reset"
        Invoke-Step "Reset TCP/IP Stack"         "netsh int ip reset"
    }
    "SystemCheck" {
        $Queue.Enqueue("H|-- System Check ------------------------------------------------------------")
        $Queue.Enqueue("I|  Note: DISM RestoreHealth may take 10-20 minutes.")
        Invoke-Step "DISM RestoreHealth" "DISM /Online /Cleanup-Image /RestoreHealth"
        Invoke-Step "SFC Scan"           "sfc /scannow"
        Invoke-Step "CHKDSK C: Scan"    "chkdsk C: /scan"
    }
    "WindowsUpdate" {
        $Queue.Enqueue("H|-- Reset Windows Update -----------------------------------------------------")
        $cmd = "net stop wuauserv & net stop bits & net stop cryptsvc & net stop msiserver & " +
               "ren C:\Windows\SoftwareDistribution SoftwareDistribution.old 2>nul & " +
               "ren C:\Windows\System32\catroot2 catroot2.old 2>nul & " +
               "net start msiserver & net start cryptsvc & net start bits & net start wuauserv"
        Invoke-Step "Reset Windows Update" $cmd
    }
    "MemoryDiag" {
        $Queue.Enqueue("H|-- Windows Memory Diagnostic -----------------------------------------------")
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        [IO.File]::AppendAllText($ReportPath,
            "`n$("-"*79)`n[$ts] Windows Memory Diagnostic`n", [Text.Encoding]::UTF8)
        try {
            Start-Process mdsched.exe
            [IO.File]::AppendAllText($ReportPath,
                "Result    : PASS`nExit Code : 0`nMessage   : Launched.`n",
                [Text.Encoding]::UTF8)
            $Queue.Enqueue("P|    [PASS] Windows Memory Diagnostic launched.")
            $Queue.Enqueue("D|    You can schedule the test from the dialog that appeared.")
        } catch {
            [IO.File]::AppendAllText($ReportPath,
                "Result    : FAIL`nExit Code : -1`nMessage   : $($_.Exception.Message)`n",
                [Text.Encoding]::UTF8)
            $Queue.Enqueue("E|    [ERROR] $($_.Exception.Message)")
        }
        $Queue.Enqueue("I|")
    }
    "UnFuck" {
        $Queue.Enqueue("H|== UnFuck - Full Repair Sequence ===========================================")
        $Queue.Enqueue("I|  This may take 20-45 minutes. The window stays responsive throughout.")
        $Queue.Enqueue("I|")
        Invoke-Step "DISM CheckHealth"   "DISM /Online /Cleanup-Image /CheckHealth"
        Invoke-Step "DISM ScanHealth"    "DISM /Online /Cleanup-Image /ScanHealth"
        Invoke-Step "DISM RestoreHealth" "DISM /Online /Cleanup-Image /RestoreHealth"
        Invoke-Step "SFC Scan"           "sfc /scannow"
        Invoke-Step "CHKDSK C: Scan"    "chkdsk C: /scan"
        Invoke-Step "Component Cleanup"  "DISM /Online /Cleanup-Image /StartComponentCleanup"
        $upd = "net stop wuauserv & net stop bits & net stop cryptsvc & net stop msiserver & " +
               "ren C:\Windows\SoftwareDistribution SoftwareDistribution.old 2>nul & " +
               "ren C:\Windows\System32\catroot2 catroot2.old 2>nul & " +
               "net start msiserver & net start cryptsvc & net start bits & net start wuauserv"
        Invoke-Step "Reset Windows Update" $upd
        Invoke-Step "Stop Print Spooler"  "net stop spooler"
        $q = "$env:SystemRoot\System32\spool\PRINTERS"
        if (Test-Path $q) {
            Remove-Item "$q\*" -Force -ErrorAction SilentlyContinue
            $Queue.Enqueue("D|    Print queue cleared.")
        }
        Invoke-Step "Start Print Spooler" "net start spooler"
        Invoke-Step "Flush DNS"           "ipconfig /flushdns"
        Invoke-Step "Reset Winsock"       "netsh winsock reset"
        Invoke-Step "Reset TCP/IP"        "netsh int ip reset"
    }
}
'@

# ==============================================================================
# START TASK  (UI thread)
# ==============================================================================
function Start-Task([string]$TaskName) {
    if ($script:IsBusy) {
        [Windows.Forms.MessageBox]::Show(
            "An operation is already running.`nPlease wait for it to complete.",
            "Busy", "OK", "Warning") | Out-Null
        return
    }
    Initialize-Report

    $script:IsBusy    = $true
    $statusLabel.Text = "Running: $TaskName ..."
    foreach ($b in $script:AllButtons) { $b.Enabled = $false }

    $script:RS = [RunspaceFactory]::CreateRunspace()
    $script:RS.ApartmentState = "STA"
    $script:RS.ThreadOptions  = "ReuseThread"
    $script:RS.Open()
    $script:RS.SessionStateProxy.SetVariable("Queue",      $script:MsgQueue)
    $script:RS.SessionStateProxy.SetVariable("ReportPath", $ReportPath)
    $script:RS.SessionStateProxy.SetVariable("TaskName",   $TaskName)

    $script:PSInst = [PowerShell]::Create()
    $script:PSInst.Runspace = $script:RS
    [void]$script:PSInst.AddScript($BackgroundScript)
    $script:Handle = $script:PSInst.BeginInvoke()
}

# ==============================================================================
# COLORS
# ==============================================================================
$cBG      = [Drawing.Color]::FromArgb(15, 15, 18)
$cPanel   = [Drawing.Color]::FromArgb(24, 24, 28)
$cLog     = [Drawing.Color]::FromArgb(10, 10, 12)
$cFG      = [Drawing.Color]::FromArgb(210, 210, 218)
$cDim     = [Drawing.Color]::FromArgb(95, 95, 110)
$cBtnN    = [Drawing.Color]::FromArgb(38, 38, 45)
$cBtnH    = [Drawing.Color]::FromArgb(55, 55, 64)
$cGreen   = [Drawing.Color]::FromArgb(45, 200, 90)
$cRed     = [Drawing.Color]::FromArgb(220, 58, 48)
$cCyan    = [Drawing.Color]::FromArgb(70, 185, 230)
$cDanger  = [Drawing.Color]::FromArgb(160, 28, 20)
$cDangerH = [Drawing.Color]::FromArgb(195, 48, 36)
$cStatus  = [Drawing.Color]::FromArgb(0, 68, 128)
$cSep     = [Drawing.Color]::FromArgb(46, 46, 56)
$cWhite   = [Drawing.Color]::White

# ==============================================================================
# FONTS
# ==============================================================================
$fMono  = New-Object Drawing.Font("Consolas",  9)
$fUI    = New-Object Drawing.Font("Segoe UI",  9.5)
$fUIB   = New-Object Drawing.Font("Segoe UI",  9.5, [Drawing.FontStyle]::Bold)
$fTitle = New-Object Drawing.Font("Segoe UI",  12,  [Drawing.FontStyle]::Bold)
$fSm    = New-Object Drawing.Font("Segoe UI",  8)

# ==============================================================================
# FORM
# ==============================================================================
$form = New-Object Windows.Forms.Form
$form.Text          = "Simple System Health Tool"
$form.Size          = New-Object Drawing.Size(1000, 670)
$form.MinimumSize   = New-Object Drawing.Size(820,  540)
$form.StartPosition = "CenterScreen"
$form.BackColor     = $cBG
$form.ForeColor     = $cFG
$form.Font          = $fUI

# ==============================================================================
# LEFT PANEL  (fixed-width, absolute layout)
# ==============================================================================
$pLeft           = New-Object Windows.Forms.Panel
$pLeft.Dock      = "Left"
$pLeft.Width     = 276
$pLeft.BackColor = $cPanel

# Title label
$lTitle           = New-Object Windows.Forms.Label
$lTitle.Text      = "SYSTEM HEALTH"
$lTitle.Font      = $fTitle
$lTitle.ForeColor = $cFG
$lTitle.AutoSize  = $false
$lTitle.Bounds    = [Drawing.Rectangle]::new(16, 18, 244, 28)
$pLeft.Controls.Add($lTitle)

# Admin badge
$lAdmin           = New-Object Windows.Forms.Label
$lAdmin.Text      = "  Running as Administrator"
$lAdmin.Font      = $fSm
$lAdmin.ForeColor = $cGreen
$lAdmin.AutoSize  = $false
$lAdmin.Bounds    = [Drawing.Rectangle]::new(14, 50, 244, 16)
$pLeft.Controls.Add($lAdmin)

# Separator helper
function Add-Separator {
    param($Panel, $Y)
    $s           = New-Object Windows.Forms.Panel
    $s.Bounds    = [Drawing.Rectangle]::new(14, $Y, 246, 1)
    $s.BackColor = $cSep
    $Panel.Controls.Add($s) | Out-Null
}
Add-Separator $pLeft 74

# ------------------------------------------------------------------
# Action buttons
# ------------------------------------------------------------------
# Each entry: Label text, TaskName key, Description, IsDanger
$btnDefs = @(
    @{ L="1   Reset Print Spooler";  K="PrintSpooler"; D="Restart print service, clear queue";     Red=$false },
    @{ L="2   Reset Network";        K="NetworkReset";  D="Reset adapters, IP, DNS and Winsock";    Red=$false },
    @{ L="3   System Check";         K="SystemCheck";   D="DISM RestoreHealth + SFC + CHKDSK";      Red=$false },
    @{ L="4   Reset Windows Update"; K="WindowsUpdate"; D="Reset update services and cache";        Red=$false },
    @{ L="5   Memory Diagnostic";    K="MemoryDiag";    D="Open the memory test scheduler";         Red=$false },
    @{ L="6   UnFuck";               K="UnFuck";        D="Full repair sequence  (20-45 min)";       Red=$true  }
)

$actionBtns = @{}
$yPos = 84

foreach ($def in $btnDefs) {
    $bgNorm  = if ($def.Red) { $cDanger  } else { $cBtnN }
    $bgHover = if ($def.Red) { $cDangerH } else { $cBtnH }

    $btn = New-Object Windows.Forms.Button
    $btn.Text      = $def.L
    $btn.Font      = $fUIB
    $btn.FlatStyle = "Flat"
    $btn.Bounds    = [Drawing.Rectangle]::new(14, $yPos, 248, 34)
    $btn.TextAlign = "MiddleLeft"
    $btn.Padding   = New-Object Windows.Forms.Padding(10, 0, 0, 0)
    $btn.Cursor    = [Windows.Forms.Cursors]::Hand
    $btn.Tag       = $def.K
    $btn.BackColor = $bgNorm
    $btn.ForeColor = $cFG
    $btn.FlatAppearance.BorderSize         = 0
    $btn.FlatAppearance.MouseOverBackColor = $bgHover
    # param($s,$e) ensures correct sender reference on all PS versions
    $btn.Add_Click({
        param($s, $e)
        Start-Task $s.Tag
    })
    $pLeft.Controls.Add($btn) | Out-Null

    $lDesc           = New-Object Windows.Forms.Label
    $lDesc.Text      = $def.D
    $lDesc.Font      = $fSm
    $lDesc.ForeColor = $cDim
    $lDesc.Bounds    = [Drawing.Rectangle]::new(24, ($yPos + 36), 238, 14)
    $pLeft.Controls.Add($lDesc) | Out-Null

    $actionBtns[$def.K] = $btn
    $yPos += 57
}

Add-Separator $pLeft ($yPos + 6)
$yPos += 18

# Open Report button
$btnReport           = New-Object Windows.Forms.Button
$btnReport.Text      = "Open Report File"
$btnReport.Font      = $fUI
$btnReport.FlatStyle = "Flat"
$btnReport.Bounds    = [Drawing.Rectangle]::new(14, $yPos, 248, 30)
$btnReport.BackColor = $cBtnN
$btnReport.ForeColor = $cFG
$btnReport.FlatAppearance.BorderSize         = 0
$btnReport.FlatAppearance.MouseOverBackColor = $cBtnH
$btnReport.Cursor    = [Windows.Forms.Cursors]::Hand
$btnReport.Add_Click({
    Initialize-Report
    Start-Process notepad.exe -ArgumentList "`"$ReportPath`""
})
$pLeft.Controls.Add($btnReport) | Out-Null
$yPos += 38

# Exit button
$btnExit           = New-Object Windows.Forms.Button
$btnExit.Text      = "Exit"
$btnExit.Font      = $fUI
$btnExit.FlatStyle = "Flat"
$btnExit.Bounds    = [Drawing.Rectangle]::new(14, $yPos, 248, 30)
$btnExit.BackColor = $cBtnN
$btnExit.ForeColor = $cDim
$btnExit.FlatAppearance.BorderSize         = 0
$btnExit.FlatAppearance.MouseOverBackColor = $cBtnH
$btnExit.Cursor    = [Windows.Forms.Cursors]::Hand
$btnExit.Add_Click({
    if ($script:IsBusy) {
        $r = [Windows.Forms.MessageBox]::Show(
            "An operation is still running.`nExit anyway?",
            "Confirm Exit", "YesNo", "Warning")
        if ($r -ne "Yes") { return }
    }
    $pollingTimer.Stop()
    $form.Close()
})
$pLeft.Controls.Add($btnExit) | Out-Null

# All buttons (for enable/disable toggling while busy)
$script:AllButtons = [System.Collections.Generic.List[System.Windows.Forms.Button]]::new()
$script:AllButtons.Add($btnReport)
$script:AllButtons.Add($btnExit)
foreach ($b in $actionBtns.Values) { $script:AllButtons.Add($b) }

# ==============================================================================
# RIGHT PANEL  (log output)
# IMPORTANT: add Top-docked header FIRST, then Fill-docked log box.
# WinForms docks in Controls collection order, so Top must come before Fill.
# ==============================================================================
$pRight           = New-Object Windows.Forms.Panel
$pRight.Dock      = "Fill"
$pRight.BackColor = $cBG

$lLogHdr           = New-Object Windows.Forms.Label
$lLogHdr.Text      = "  OUTPUT LOG"
$lLogHdr.Font      = New-Object Drawing.Font("Segoe UI", 7.5, [Drawing.FontStyle]::Bold)
$lLogHdr.ForeColor = $cDim
$lLogHdr.BackColor = [Drawing.Color]::FromArgb(18, 18, 22)
$lLogHdr.Dock      = "Top"
$lLogHdr.Height    = 22
$lLogHdr.TextAlign = "MiddleLeft"
$pRight.Controls.Add($lLogHdr) | Out-Null   # <-- Top first

$logBox            = New-Object Windows.Forms.RichTextBox
$logBox.Dock       = "Fill"
$logBox.BackColor  = $cLog
$logBox.ForeColor  = $cFG
$logBox.Font       = $fMono
$logBox.ReadOnly   = $true
$logBox.BorderStyle = "None"
$logBox.ScrollBars = "Vertical"
$logBox.WordWrap   = $true
$pRight.Controls.Add($logBox) | Out-Null     # <-- Fill second

# ==============================================================================
# STATUS BAR
# ==============================================================================
$statusStrip           = New-Object Windows.Forms.StatusStrip
$statusStrip.BackColor = $cStatus
$statusStrip.SizingGrip = $false

$statusLabel           = New-Object Windows.Forms.ToolStripStatusLabel
$statusLabel.Text      = "Ready"
$statusLabel.ForeColor = $cWhite
$statusLabel.Font      = $fSm
[void]$statusStrip.Items.Add($statusLabel)

$statusPath           = New-Object Windows.Forms.ToolStripStatusLabel
$statusPath.Text      = "Report: $ReportPath"
$statusPath.ForeColor = [Drawing.Color]::FromArgb(150, 195, 255)
$statusPath.Font      = $fSm
$statusPath.Spring    = $true
$statusPath.TextAlign = "MiddleRight"
[void]$statusStrip.Items.Add($statusPath)

# ==============================================================================
# ASSEMBLE FORM
# (Add Fill panels before Left panels; Controls added last paint on top)
# ==============================================================================
$form.Controls.Add($pRight)
$form.Controls.Add($pLeft)
$form.Controls.Add($statusStrip)

# ==============================================================================
# LOG HELPERS  (UI thread only - called from timer tick)
# ==============================================================================
function Append-Log([string]$Text, [Drawing.Color]$Color) {
    $logBox.SelectionStart  = $logBox.TextLength
    $logBox.SelectionLength = 0
    $logBox.SelectionColor  = $Color
    $logBox.AppendText($Text + "`n")
    $logBox.SelectionColor  = $cFG
    $logBox.ScrollToCaret()
}

function Show-QueuedMessage([string]$Msg) {
    if ($Msg.Length -ge 2 -and $Msg[1] -eq '|') {
        $col = switch ($Msg[0]) {
            'H' { $cCyan  }
            'P' { $cGreen }
            'F' { $cRed   }
            'E' { $cRed   }
            'D' { $cDim   }
            default { $cFG }
        }
        Append-Log $Msg.Substring(2) $col
    } else {
        Append-Log $Msg $cFG
    }
}

# ==============================================================================
# POLLING TIMER - drains queue, detects task completion
# ==============================================================================
$pollingTimer          = New-Object Windows.Forms.Timer
$pollingTimer.Interval = 80
$pollingTimer.Add_Tick({
    $msg = ""
    while ($script:MsgQueue.TryDequeue([ref]$msg)) { Show-QueuedMessage $msg }

    if ($script:IsBusy -and $null -ne $script:Handle -and $script:Handle.IsCompleted) {
        # Drain any remaining messages
        while ($script:MsgQueue.TryDequeue([ref]$msg)) { Show-QueuedMessage $msg }

        if ($script:PSInst.HadErrors) {
            Append-Log "" $cFG
            Append-Log "[!] One or more steps reported errors - see report for details." $cRed
        } else {
            Append-Log "" $cFG
            Append-Log "Done." $cGreen
        }
        Append-Log "Report: $ReportPath" $cDim
        Append-Log ("-" * 68) $cSep

        # Cleanup
        try { $script:PSInst.Dispose()                          } catch {}
        try { $script:RS.Close(); $script:RS.Dispose()          } catch {}
        $script:PSInst  = $null
        $script:RS      = $null
        $script:Handle  = $null
        $script:IsBusy  = $false

        $statusLabel.Text = "Ready"
        foreach ($b in $script:AllButtons) { $b.Enabled = $true }
    }
})
$pollingTimer.Start()

# ==============================================================================
# FORM CLOSING
# ==============================================================================
$form.Add_FormClosing({
    $pollingTimer.Stop()
    if ($script:PSInst) { try { $script:PSInst.Dispose()               } catch {} }
    if ($script:RS)     { try { $script:RS.Close(); $script:RS.Dispose() } catch {} }
})

# ==============================================================================
# WELCOME LOG
# ==============================================================================
Initialize-Report

Append-Log "Simple System Health Tool  v3.1" $cCyan
Append-Log "Computer : $($env:COMPUTERNAME)   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" $cDim
Append-Log "Report   : $ReportPath" $cDim
Append-Log ("-" * 68) $cSep
Append-Log "Select an operation from the left panel to begin." $cFG
Append-Log "" $cFG

# ==============================================================================
# RUN
# ==============================================================================
[Windows.Forms.Application]::Run($form)
