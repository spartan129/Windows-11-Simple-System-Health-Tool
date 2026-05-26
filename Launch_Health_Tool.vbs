' Simple System Health Tool - Launcher
' Double-click this to run the tool with no console window.
' The PowerShell script handles UAC elevation itself.

Dim objShell, objFSO, strDir, strPS1, strCmd

Set objShell = CreateObject("WScript.Shell")
Set objFSO   = CreateObject("Scripting.FileSystemObject")

strDir = objFSO.GetParentFolderName(WScript.ScriptFullName)
strPS1 = strDir & "\Simple_System_Health_Tool_GUI.ps1"

If Not objFSO.FileExists(strPS1) Then
    MsgBox "Cannot find Simple_System_Health_Tool_GUI.ps1" & vbCrLf & _
           "Make sure both files are in the same folder.", _
           vbCritical, "Simple System Health Tool"
    WScript.Quit 1
End If

' Window style 0 = hidden. No console window appears at all.
strCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & strPS1 & """"
objShell.Run strCmd, 0, False

Set objShell = Nothing
Set objFSO   = Nothing
