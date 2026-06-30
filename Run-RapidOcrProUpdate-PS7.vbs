Dim shell, fso, scriptDir, pwsh, command, splashPath

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
splashPath = scriptDir & "\RapidOcrStartupSplash.hta"

pwsh = "pwsh"
command = """" & pwsh & """ -NoProfile -ExecutionPolicy Bypass -STA -File """ & scriptDir & "\RapidOcrProUpdate.ps1"""

shell.CurrentDirectory = scriptDir
If fso.FileExists(splashPath) Then
    shell.Run "mshta.exe """ & splashPath & """", 1, False
End If
shell.Run command, 0, False
