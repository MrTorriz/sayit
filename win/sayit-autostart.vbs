' sayit-autostart.vbs - launches the supervisor with no console window at all.
'
' The scheduled task registered by win\install.ps1 runs this through
' wscript.exe. wscript has no console of its own and starts the supervisor with
' a hidden window, so nothing ever appears on screen.
'
' powershell.exe -WindowStyle Hidden is not enough on its own. The host creates
' its console first and applies the flag only once it is already running, and
' sayit-autostart.ps1 can only hide the window after it has compiled the call
' that hides it - measured at about 140 ms on an idle machine, and far longer at
' logon when everything starts at once. The console sits on the desktop for that
' whole time. This removes the race rather than trying to win it.
'
' Nothing else belongs in here. The supervisor keeps all the logic; this exists
' only to start it without a console.

Option Explicit

Dim shell, here, script, command
Set shell = CreateObject("WScript.Shell")

here = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
script = here & "sayit-autostart.ps1"

command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & script & """"

' 0 = hidden window, False = do not wait. wscript exits immediately and the
' supervisor keeps running, which is what lets the task's repetition act as a
' watchdog: a repeat that finds a live supervisor is refused by its mutex.
shell.Run command, 0, False
