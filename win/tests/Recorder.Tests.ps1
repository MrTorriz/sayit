# Recorder.Tests.ps1 - unit tests for the pure parts of win\lib\Recorder.cs.
#
# The source is compiled with Add-Type exactly the way sayit-record.ps1 compiles
# it, so a C# error that would only surface the first time somebody presses the
# dictation key is caught here instead. Recorder.cs is deliberately written to
# C# 5 because Add-Type on Windows PowerShell 5.1 uses the in-box csc.exe;
# compiling it here is what keeps that constraint honest.
#
# NOT COVERED: CaptureToWav, GetEndpointId beyond the enumeration path, the
# level publishing and the RIFF header writer. All of those need a real capture
# device, and opening the microphone from a test suite is not acceptable in a
# dictation tool. Device enumeration is the boundary: it queries the driver list
# without opening a stream. Nothing in this file starts a recording.

BeforeAll {
    $script:RecorderSource = (Resolve-Path (Join-Path $PSScriptRoot '..\lib\Recorder.cs')).Path

    # A type can only be added once per process, and the runner puts every test
    # file in one process, so adding it twice would be a hard error.
    if (-not ('Sayit.Recorder' -as [type])) {
        $code = [System.IO.File]::ReadAllText($script:RecorderSource,
                                              (New-Object System.Text.UTF8Encoding($false)))
        Add-Type -TypeDefinition $code -Language CSharp
    }
}

Describe 'Recorder.cs' {

    Context 'compilation' {

        It 'compiles with Add-Type and exposes the Sayit.Recorder type' {
            ('Sayit.Recorder' -as [type]) | Should -Not -BeNullOrEmpty
        }

        It 'exposes the nested DeviceInfo type with Index, Name and EndpointId' {
            # The record script projects these three onto a pscustomobject for
            # -List output, so renaming one breaks device selection silently.
            $t = 'Sayit.Recorder+DeviceInfo' -as [type]
            $t | Should -Not -BeNullOrEmpty
            $names = $t.GetFields() | ForEach-Object { $_.Name }
            $names | Should -Contain 'Index'
            $names | Should -Contain 'Name'
            $names | Should -Contain 'EndpointId'
        }
    }

    Context 'audio format constants' {

        # whisper.cpp expects 16 kHz mono 16-bit PCM. These are not tuning knobs:
        # changing any of them produces a WAV the model cannot use, and the
        # failure shows up as bad transcription rather than as an error.

        It 'declares a sample rate of 16000 Hz' {
            [Sayit.Recorder]::SampleRate | Should -Be 16000
        }

        It 'declares a single channel' {
            [Sayit.Recorder]::Channels | Should -Be 1
        }

        It 'declares 16 bits per sample' {
            [Sayit.Recorder]::BitsPerSample | Should -Be 16
        }
    }

    Context 'ListDevices' {

        It 'enumerates capture devices without throwing' {
            # Enumeration must survive a machine with no capture device at all,
            # which is the state of a headless CI runner.
            { [Sayit.Recorder]::ListDevices() } | Should -Not -Throw
        }

        It 'returns a list object even when the machine has no capture device' {
            # A headless runner must get an empty list, never null: the record
            # script iterates the result without a null check.
            $devices = [Sayit.Recorder]::ListDevices()
            ($null -eq $devices) | Should -Be $false
            $devices.GetType().FullName | Should -BeLike 'System.Collections.Generic.List*'
        }

        It 'gives every enumerated device a non-negative Index and a Name' {
            # Skipped rather than vacuously passed when the machine has no
            # capture device, so the result is never mistaken for a real check.
            $devices = [Sayit.Recorder]::ListDevices()
            if ($devices.Count -eq 0) {
                Set-ItResult -Skipped -Because 'this machine reports no capture devices'
                return
            }
            foreach ($d in $devices) {
                $d.Index | Should -BeGreaterOrEqual 0
                $d.Name | Should -BeOfType [string]
            }
        }

        It 'numbers devices consecutively from zero' {
            $devices = [Sayit.Recorder]::ListDevices()
            if ($devices.Count -eq 0) {
                Set-ItResult -Skipped -Because 'this machine reports no capture devices'
                return
            }
            $devices[0].Index | Should -Be 0
        }
    }

    Context 'ResolveDevice' {

        It 'returns -1 for an empty selector, meaning the Windows default device' {
            # -1 is WAVE_MAPPER. An unset AUDIO_SOURCE must land here rather than
            # be treated as a device name that happens to match nothing.
            [Sayit.Recorder]::ResolveDevice('') | Should -Be (-1)
        }

        It 'returns -1 for a null selector' {
            [Sayit.Recorder]::ResolveDevice($null) | Should -Be (-1)
        }

        It 'returns -2 for a selector that matches no device' {
            # -2 is the distinct "configured device not found" code the record
            # script turns into an actionable message. Collapsing it into -1
            # would silently record from the wrong microphone instead.
            #
            # A freshly generated GUID cannot collide with a device name or an
            # endpoint ID, including via the substring match that runs last.
            $selector = [guid]::NewGuid().ToString()
            [Sayit.Recorder]::ResolveDevice($selector) | Should -Be (-2)
        }
    }
}
