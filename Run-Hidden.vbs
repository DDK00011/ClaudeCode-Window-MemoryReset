Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptPath = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "MemoryReset.ps1")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Quote(scriptPath)

For Each arg In WScript.Arguments
    cmd = cmd & " " & Quote(arg)
Next

WScript.Quit shell.Run(cmd, 0, True)

Function Quote(value)
    Quote = """" & Replace(CStr(value), """", """""") & """"
End Function
