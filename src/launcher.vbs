' Starts the KeepSpicetifyOn tray app with no console window.
'
' Task Scheduler can only launch powershell.exe directly, and on Windows 11 the
' default terminal is Windows Terminal, which ignores -WindowStyle Hidden and
' shows an empty black window. Closing that window kills the tray app.
'
' wscript.exe has no console of its own, and Run(..., 0, False) creates the
' PowerShell process hidden, so no console or terminal window is ever created.

Option Explicit

Dim shell, fso, scriptDir, target, command

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
target = fso.BuildPath(scriptDir, "KeepSpicetifyOn.ps1")

command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & target & """"

' 0 = hidden window, False = don't wait for it to exit
shell.Run command, 0, False
