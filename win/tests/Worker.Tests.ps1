BeforeAll {
    . "$PSScriptRoot\..\lib\common.ps1"
    . "$PSScriptRoot\..\lib\transcription-worker.ps1"
}

Describe 'Warm transcription worker' {
    It 'dispatches asynchronously, stays STA and accepts consecutive sessions' {
        $worker = New-SayitTranscriptionWorker
        $release = New-Object System.Threading.ManualResetEvent($false)
        try {
            $worker.Shell.Commands.Clear()
            [void]$worker.Shell.AddScript({
                param($Release)
                $script:Release = $Release
                function Stop-Recording {
                    param($ClaimedSession)
                    if (-not $script:Release.WaitOne(10000)) { throw 'Test release timed out.' }
                    return [pscustomobject]@{
                        Value = $ClaimedSession.Value
                        Apartment = [Threading.Thread]::CurrentThread.ApartmentState.ToString()
                        Thread = [Threading.Thread]::CurrentThread.ManagedThreadId
                    }
                }
            }).AddArgument($release)
            [void]$worker.Shell.Invoke()
            $worker.Shell.HadErrors | Should -BeFalse

            $first = Start-SayitTranscription $worker ([pscustomobject]@{Value='first'})
            $first.IsCompleted | Should -BeFalse
            [void]$release.Set()
            $result = @($worker.Shell.EndInvoke($first))
            $worker.Shell.HadErrors | Should -BeFalse
            $result[0].Value | Should -Be 'first'
            $result[0].Apartment | Should -Be 'STA'

            $second = Start-SayitTranscription $worker ([pscustomobject]@{Value='second'})
            $next = @($worker.Shell.EndInvoke($second))
            $worker.Shell.HadErrors | Should -BeFalse
            $next[0].Value | Should -Be 'second'
            $next[0].Thread | Should -Be $result[0].Thread
        } finally {
            [void]$release.Set()
            $worker.Shell.Dispose()
            $worker.Runspace.Dispose()
            $release.Dispose()
        }
    }
}
