' Gal Search MVP - Silent Launcher
' Launches the PowerShell WinForms app without showing a console window.
' Portable: works from any folder, copy the whole directory anywhere.

Dim shell, fso, scriptDir, scriptPath, tmpFile
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' Get the directory where this VBS script is located
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = scriptDir & "\GalSearch.ps1"

' Create a bootstrap PS1 in the app directory (avoids encoding/com quoting issues)
tmpFile = scriptDir & "\_run.ps1"

Dim file
Set file = fso.CreateTextFile(tmpFile, True)
file.WriteLine "$p = '" & scriptPath & "'"
file.WriteLine "[System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | Invoke-Expression"
file.Close

' Run bootstrap PowerShell hidden (0 = hide window)
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -File """ & tmpFile & """", 0, False

Set file = Nothing
Set shell = Nothing
Set fso = Nothing
