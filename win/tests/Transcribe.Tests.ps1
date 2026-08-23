# Transcribe.Tests.ps1 - unit tests for the settings layer of
# win\lib\transcribe.ps1.
#
# The numbers checked here reach whisper, which parses them in the C locale. A
# Swedish .env writes 0,30, and a threshold of 30 does not degrade recognition -
# it silences it, because no frame ever scores above it and every speech segment
# is discarded. That is worth a test rather than a comment.
#
# NOT COVERED: Convert-WavToText, Invoke-WhisperDaemon and Invoke-WhisperCli.
# They need a running daemon or a several-second model load, and the test suite
# has no business depending on either. Nothing in this file transcribes, opens a
# socket or starts a process.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\common.ps1')
    . (Join-Path $PSScriptRoot '..\lib\transcribe.ps1')

    # The ambient environment wins over .env in Get-Setting, so a machine that
    # happens to export one of these would otherwise change the result.
    $script:SavedEnv = @{}
    foreach ($name in 'VAD_THRESHOLD', 'VAD_MIN_SPEECH_MS', 'VAD_MIN_SILENCE_MS', 'VAD_SPEECH_PAD_MS') {
        $script:SavedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }

    function Invoke-InCulture {
        param([string]$Culture, [scriptblock]$Body)
        $previous = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture =
                New-Object System.Globalization.CultureInfo($Culture)
            return (& $Body)
        } finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $previous
        }
    }
}

AfterAll {
    foreach ($name in $script:SavedEnv.Keys) {
        [Environment]::SetEnvironmentVariable($name, $script:SavedEnv[$name], 'Process')
    }
}

Describe 'ConvertTo-InvariantNumber' {

    It 'passes an invariant decimal through unchanged in value' {
        ConvertTo-InvariantNumber -Value '0.30' -Default '0.50' | Should -Be '0.3'
    }

    It 'never reads a decimal comma as a thousands separator' {
        # The trap this function exists for: invariant parsing with AllowThousands
        # accepts "0,30" and returns 30, and 30 as a VAD threshold discards every
        # speech segment there is.
        ConvertTo-InvariantNumber -Value '0,30' -Default '0.50' | Should -Not -Be '30'
    }

    It 'accepts a decimal comma from a Swedish locale and emits an invariant point' {
        $result = Invoke-InCulture 'sv-SE' { ConvertTo-InvariantNumber -Value '0,30' -Default '0.50' }
        $result | Should -Be '0.3'
    }

    It 'emits an invariant point even when the ambient culture uses a comma' {
        $result = Invoke-InCulture 'sv-SE' { ConvertTo-InvariantNumber -Value '0.45' -Default '0.50' }
        $result | Should -Be '0.45'
    }

    It 'falls back to the default for a value that is not a number' {
        ConvertTo-InvariantNumber -Value 'loud' -Default '0.30' | Should -Be '0.3'
    }

    It 'falls back to the default for an empty value' {
        ConvertTo-InvariantNumber -Value '' -Default '250' -Integer | Should -Be '250'
    }

    It 'returns whole numbers with -Integer' {
        ConvertTo-InvariantNumber -Value '250.4' -Default '30' -Integer | Should -Be '250'
    }

    It 'keeps zero, which is a meaningful value rather than an absent one' {
        # VAD_MIN_SPEECH_MS=0 is what stops whisper deleting a one-word answer
        # outright, so 0 must never be treated as "unset" and replaced.
        ConvertTo-InvariantNumber -Value '0' -Default '250' -Integer | Should -Be '0'
    }
}

Describe 'New-TranscribeSettings' {

    BeforeAll {
        $script:Settings = New-TranscribeSettings -Env @{}
    }

    It 'resolves every VAD setting to an invariant string' {
        foreach ($name in 'VadThreshold', 'VadMinSpeechMs', 'VadMinSilenceMs', 'VadSpeechPadMs') {
            $value = $script:Settings.$name
            $value | Should -Not -BeNullOrEmpty
            $value | Should -Not -Match ','
        }
    }

    It 'defaults the speech padding well above whisper own 30 ms' {
        # Padding is the only parameter that adds audio after the frame where the
        # segment was pinned, and 30 ms is inside a Swedish unvoiced final.
        [int]$script:Settings.VadSpeechPadMs | Should -BeGreaterThan 30
    }

    It 'defaults the minimum speech duration to 0' {
        $script:Settings.VadMinSpeechMs | Should -Be '0'
    }

    It 'defaults the threshold below whisper own 0.5' {
        [double]::Parse($script:Settings.VadThreshold,
                        [System.Globalization.CultureInfo]::InvariantCulture) | Should -BeLessThan 0.5
    }

    It 'points the daemon at loopback only' {
        # The daemon has no authentication, so the URL must never be reachable
        # from anywhere but this machine.
        $script:Settings.DaemonUrl | Should -BeLike 'http://127.0.0.1:*'
    }

    It 'lets .env override a default' {
        $s = New-TranscribeSettings -Env @{ VAD_SPEECH_PAD_MS = '400'; SPEECH_LANGUAGE = 'en' }
        $s.VadSpeechPadMs | Should -Be '400'
        $s.Language | Should -Be 'en'
    }
}
