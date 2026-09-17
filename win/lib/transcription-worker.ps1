# One warm STA runspace for transcription and text delivery. The trigger keeps
# pumping input while this worker runs the existing stop-to-text pipeline.
function New-SayitTranscriptionWorker {
    $space = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $space.ApartmentState = 'STA'
    $space.ThreadOptions = 'ReuseThread'
    $space.Open()
    $shell = [System.Management.Automation.PowerShell]::Create()
    $shell.Runspace = $space
    try {
        [void]$shell.AddScript({
            param($Root)
            . "$Root\sayit.ps1" -Library
            . "$Root\lib\transcribe.ps1"
            . "$Root\lib\inject.ps1"
            Initialize-Injector
        }).AddArgument($script:WinRoot)
        [void]$shell.Invoke()
        if ($shell.HadErrors) { throw $shell.Streams.Error[0] }
        return [pscustomobject]@{ Shell=$shell; Runspace=$space }
    } catch {
        $shell.Dispose(); $space.Dispose(); throw
    }
}

function Start-SayitTranscription {
    param($Worker, $Session)
    $Worker.Shell.Commands.Clear()
    $Worker.Shell.Streams.Error.Clear()
    [void]$Worker.Shell.AddScript({
        param($Completed)
        $cfg = Import-DotEnv
        Stop-Recording -ClaimedSession $Completed
    }).AddArgument($Session)
    return $Worker.Shell.BeginInvoke()
}
