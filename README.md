# Simple System Health Tool

A lightweight, GUI-based Windows maintenance utility built entirely in PowerShell — no compiled executables, no encoded commands, no third-party dependencies.

---

## Download

Download both files and place them in the **same folder**:

| File | Description |
|---|---|
| [`Launch_Health_Tool.vbs`](Launch_Health_Tool.vbs) | Double-click launcher — opens the tool with no console window |
| [`Simple_System_Health_Tool_GUI.ps1`](Simple_System_Health_Tool_GUI.ps1) | The main PowerShell script |

> **Both files must be in the same folder for the launcher to work.**

---

## How to Run

1. Download both files into the same folder.
2. Double-click **`Launch_Health_Tool.vbs`**.
3. When prompted by Windows UAC, click **Yes** to allow Administrator access (required for system repairs).
4. The GUI will open and you're ready to go.

> You do not need to change any PowerShell execution policy settings — the launcher handles this automatically.

---

## What It Does

The tool provides a clean dark-themed GUI with six maintenance operations, each running in the background so the window stays responsive throughout.

### Operations

| # | Button | What it does |
|---|---|---|
| 1 | **Reset Print Spooler** | Stops the print spooler service, clears the printer queue, then restarts the service. Useful when jobs are stuck. |
| 2 | **Reset Network** | Disables and re-enables physical network adapters, releases and renews your IP address, flushes the DNS cache, and resets the Winsock catalog and TCP/IP stack. |
| 3 | **System Check** | Runs DISM RestoreHealth, SFC (System File Checker), and a CHKDSK scan on C:. Can take 10–20 minutes. |
| 4 | **Reset Windows Update** | Stops Windows Update services, renames the corrupted SoftwareDistribution and catroot2 folders, then restarts the services — a standard fix for broken Windows Updates. |
| 5 | **Memory Diagnostic** | Opens the built-in Windows Memory Diagnostic scheduler so you can test your RAM on next reboot. |
| 6 | **UnFuck** *(Full Repair)* | Runs everything: DISM CheckHealth → ScanHealth → RestoreHealth → SFC → CHKDSK → Component Cleanup → Windows Update reset → Print Spooler reset → DNS flush → Winsock and TCP/IP reset. Expect **20–45 minutes**. |

### Report File

Every operation is automatically logged to a `.txt` report file saved in the same folder as the script, named after your computer (e.g. `DESKTOPSystemHealth.txt`). The report includes your computer name, Windows version, build number, serial number, and a timestamped log of every step's result and exit code.

Click **Open Report File** in the GUI at any time to view it in Notepad.

---

## Requirements

- Windows 10 or Windows 11
- PowerShell 5.1 or later (built into Windows by default)
- Administrator privileges (the tool self-elevates via UAC prompt)

---

## Notes

- All operations run in a background thread — the GUI remains responsive while tasks execute.
- If you close the window while a task is running, you'll be asked to confirm before exiting.
- No data is sent anywhere. Everything runs locally on your machine.
