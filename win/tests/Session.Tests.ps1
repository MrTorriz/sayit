# Session.Tests.ps1 - unit tests for the session-file helpers in
# win\lib\common.ps1.
#
# The session file is what one dictation hands to the next command: sayit.ps1
# signals, waits for and can ultimately kill the process it names. Two things
# therefore have to hold, and both are checked here rather than by pressing the
# dictation key: the start stamp must survive a decimal-comma locale, and the
# pid must be treated as an identity rather than as a bare number, because
# Windows hands pids out again.
#
# NOT COVERED: the state machine around these helpers. Claiming, spawning and
# stopping a recorder need a real capture device, and opening the microphone
# from a test suite is not acceptable in a dictation tool. Nothing in this file
# starts a recording or a process.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\common.ps1')

    $script:SelfStart = (Get-Process -Id $PID).StartTime.ToFileTimeUtc()

    # A pid nothing is using, so "no such process" is tested for real.
    $script:FreePid = 0
    foreach ($candidate in 999996, 999992, 999988, 4000000, 4000004) {
        if (-not (Get-Process -Id $candidate -ErrorAction SilentlyContinue)) {
            $script:FreePid = $candidate
            break
        }
    }

    function New-SessionLine {
        param([string[]]$Fields)
        return ($Fields -join "`t")
    }
}

Describe 'ConvertFrom-SessionLine' {

    Context 'a complete line' {

        It 'parses all five fields' {
            $s = ConvertFrom-SessionLine -Line (New-SessionLine @('1234', 'C:\run\sayit-1234.wav',
                                                                 '1700000000.25', 'Local\sayit-stop-1234',
                                                                 '132000000000000000'))
            $s.ProcessId    | Should -Be 1234
            $s.Wav          | Should -Be 'C:\run\sayit-1234.wav'
            $s.Start        | Should -Be 1700000000.25
            $s.EventName    | Should -Be 'Local\sayit-stop-1234'
            $s.ProcessStart | Should -Be 132000000000000000
        }

        It 'reads the start stamp with the invariant culture under a decimal-comma locale' {
            # sayit.ps1 writes this field invariantly. Parsing it with a Swedish
            # culture reads "1700000000.25" as an integer several orders of
            # magnitude too large, which turns every duration in history.jsonl
            # into nonsense without any error.
            $previous = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [System.Threading.Thread]::CurrentThread.CurrentCulture =
                    New-Object System.Globalization.CultureInfo('sv-SE')
                $s = ConvertFrom-SessionLine -Line (New-SessionLine @('1', 'w', '1700000000.25', 'e', '0'))
                $s.Start | Should -Be 1700000000.25
            } finally {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = $previous
            }
        }

        It 'reads the identity field with the invariant culture as well' {
            $s = ConvertFrom-SessionLine -Line (New-SessionLine @('1', 'w', '1.0', 'e', '132000000000000000'))
            $s.ProcessStart | Should -BeOfType [long]
        }

        It 'tolerates a trailing newline' {
            $s = ConvertFrom-SessionLine -Line ((New-SessionLine @('7', 'w', '1.0', 'e', '5')) + "`n")
            $s.ProcessStart | Should -Be 5
        }
    }

    Context 'a line written before the identity field existed' {

        It 'still parses, and reports 0 for the recorder creation time' {
            # 0 means "cannot verify". It must never be mistaken for a match:
            # that is what would let a stale session get an unrelated process
            # killed. A live session written by an older version still stops.
            $s = ConvertFrom-SessionLine -Line (New-SessionLine @('1234', 'w', '1.0', 'Local\e'))
            $s | Should -Not -BeNullOrEmpty
            $s.ProcessStart | Should -Be 0
        }

        It 'reports 0 for an identity field that is not a number' {
            $s = ConvertFrom-SessionLine -Line (New-SessionLine @('1234', 'w', '1.0', 'Local\e', 'rubbish'))
            $s.ProcessStart | Should -Be 0
        }
    }

    Context 'a damaged line' {

        It 'returns nothing for fewer than four fields' {
            # Start-RecordingLocked deletes what it cannot parse, so returning a
            # half-built object here would leave a recorder nothing can stop.
            ConvertFrom-SessionLine -Line (New-SessionLine @('1234', 'w', '1.0')) | Should -BeNullOrEmpty
        }

        It 'returns nothing for an empty line' {
            ConvertFrom-SessionLine -Line '' | Should -BeNullOrEmpty
        }

        It 'returns nothing for a line with no tabs at all' {
            ConvertFrom-SessionLine -Line 'not a session file' | Should -BeNullOrEmpty
        }
    }
}

Describe 'Test-SessionRecorder' {

    It 'accepts a live process whose creation time matches' {
        $s = [pscustomobject]@{ ProcessId = $PID; ProcessStart = $script:SelfStart }
        Test-SessionRecorder $s | Should -Be $true
    }

    It 'rejects a live pid whose creation time does not match' {
        # This is pid reuse: the number is in use, but by something else. Before
        # the creation time was checked, stop signalled, waited four seconds for
        # and then force-killed whatever process had inherited the number.
        $s = [pscustomobject]@{ ProcessId = $PID; ProcessStart = ($script:SelfStart + 1) }
        Test-SessionRecorder $s | Should -Be $false
    }

    It 'rejects a pid that no process holds' {
        if ($script:FreePid -eq 0) {
            Set-ItResult -Skipped -Because 'every candidate pid was in use'
            return
        }
        $s = [pscustomobject]@{ ProcessId = $script:FreePid; ProcessStart = $script:SelfStart }
        Test-SessionRecorder $s | Should -Be $false
    }

    It 'rejects a null session' {
        Test-SessionRecorder $null | Should -Be $false
    }

    It 'accepts a live pid from a session with no identity field' {
        # Unverifiable, not disproved: a session written by an older version has
        # to keep stopping. sayit.ps1 signals it but refuses to force-kill it.
        $s = [pscustomobject]@{ ProcessId = $PID; ProcessStart = 0 }
        Test-SessionRecorder $s | Should -Be $true
    }
}
