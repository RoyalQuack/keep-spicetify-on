' Starts the KeepSpicetifyOn tray app with no console window.
'
' Task Scheduler can only launch powershell.exe directly, and on Windows 11 the
' default terminal is Windows Terminal, which ignores -WindowStyle Hidden and
' shows an empty black window. Closing that window kills the tray app.
'
' wscript.exe has no console of its own, and Run(..., 0, False) creates the
' PowerShell process hidden, so no console or terminal window is ever created.

' An optional first argument is a delay in milliseconds. A self-update uses it so
' the outgoing tray has exited and released the single-instance mutex before the
' replacement starts, otherwise the new one would see itself as a duplicate.

Option Explicit

Dim shell, fso, scriptDir, target, command, delayMs

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

delayMs = 0
If WScript.Arguments.Count > 0 Then
    If IsNumeric(WScript.Arguments(0)) Then delayMs = CLng(WScript.Arguments(0))
End If
If delayMs > 0 Then WScript.Sleep delayMs

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
target = fso.BuildPath(scriptDir, "KeepSpicetifyOn.ps1")

command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & target & """"

' 0 = hidden window, False = don't wait for it to exit
shell.Run command, 0, False
