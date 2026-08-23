# Utf8.Tests.ps1 - unit tests for the UTF-8 file helpers in win\lib\common.ps1.
#
# Windows PowerShell 5.1 has no way to write a BOM-less UTF-8 file with the
# built-in cmdlets: Out-File -Encoding utf8 and Set-Content -Encoding utf8 both
# emit EF BB BF. history.jsonl is read line by line by strict JSONL readers,
# including the ones on the Linux side of this repository, and a BOM on the
# first line makes that line fail to parse. Write-Utf8Text, Add-Utf8Line and
# Read-Utf8Text exist for exactly that reason, so a regression that reintroduces
# a BOM would silently corrupt shared history.
#
# All files are written under $TestDrive; the real history file is never opened.
#
# NOTE: this file is stored as UTF-8 WITH a byte order mark. Windows PowerShell
# 5.1 decodes a BOM-less script file using the ANSI code page, which would turn
# the Swedish literals below into mojibake and make the round-trip tests assert
# something other than what they read as.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\common.ps1')

    $script:FileCounter = 0

    function New-TempPath {
        param([string]$Extension = '.txt')
        $script:FileCounter++
        return (Join-Path $TestDrive ('utf8-{0}{1}' -f $script:FileCounter, $Extension))
    }

    # A file must not start with the UTF-8 byte order mark EF BB BF.
    function Assert-NoBom {
        param([Parameter(Mandatory)][string]$Path)
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -ge 3) {
            $isBom = ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)
            $isBom | Should -Be $false -Because 'a byte order mark corrupts the first line for strict JSONL readers'
        }
    }

    # Swedish text with characters that are multi-byte in UTF-8 and single-byte
    # in every Windows ANSI code page, so a mis-encoded write is detectable.
    $script:Swedish = 'räksmörgås på Öland'
}

Describe 'Write-Utf8Text' {

    It 'writes no byte order mark' {
        $path = New-TempPath
        Write-Utf8Text -Path $path -Text 'plain ascii'
        Assert-NoBom -Path $path
        [System.IO.File]::ReadAllBytes($path)[0] | Should -Be ([byte][char]'p')
    }

    It 'writes no byte order mark when the text begins with a non-ASCII character' {
        $path = New-TempPath
        Write-Utf8Text -Path $path -Text $script:Swedish
        Assert-NoBom -Path $path
    }

    It 'writes exactly the text with no trailing newline added' {
        $path = New-TempPath
        Write-Utf8Text -Path $path -Text 'no newline'
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes.Length | Should -Be 10
        $bytes[$bytes.Length - 1] | Should -Not -Be 10
    }

    It 'produces a zero-byte file for empty text' {
        $path = New-TempPath
        Write-Utf8Text -Path $path -Text ''
        (Get-Item -LiteralPath $path).Length | Should -Be 0
    }

    It 'encodes Swedish characters as UTF-8 rather than as a single-byte code page' {
        $path = New-TempPath
        Write-Utf8Text -Path $path -Text $script:Swedish
        $bytes = [System.IO.File]::ReadAllBytes($path)
        # Five non-ASCII characters, each two bytes in UTF-8.
        $bytes.Length | Should -Be ($script:Swedish.Length + 5)
    }

    It 'overwrites rather than appends' {
        $path = New-TempPath
        Write-Utf8Text -Path $path -Text 'first'
        Write-Utf8Text -Path $path -Text 'second'
        Read-Utf8Text -Path $path | Should -Be 'second'
    }
}

Describe 'Add-Utf8Line' {

    It 'writes no byte order mark when it creates the file' {
        $path = New-TempPath '.jsonl'
        Add-Utf8Line -Path $path -Line '{"text":"hello"}'
        Assert-NoBom -Path $path
        [System.IO.File]::ReadAllBytes($path)[0] | Should -Be ([byte][char]'{')
    }

    It 'terminates the line with a single LF and never CRLF' {
        # history.jsonl is shared with the Linux side. A CR before the LF ends up
        # inside the last JSON value for readers that split on LF alone.
        $path = New-TempPath '.jsonl'
        Add-Utf8Line -Path $path -Line 'value'
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes.Length | Should -Be 6
        $bytes[5] | Should -Be 10
        $bytes[4] | Should -Not -Be 13
    }

    It 'appends further lines instead of replacing the file' {
        $path = New-TempPath '.jsonl'
        Add-Utf8Line -Path $path -Line 'one'
        Add-Utf8Line -Path $path -Line 'two'
        Read-Utf8Text -Path $path | Should -Be "one`ntwo`n"
    }

    It 'writes no byte order mark on any appended line' {
        $path = New-TempPath '.jsonl'
        Add-Utf8Line -Path $path -Line 'one'
        Add-Utf8Line -Path $path -Line 'two'
        Assert-NoBom -Path $path
        # A BOM inserted mid-file would show up as EF BB BF after the first LF.
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes[4] | Should -Not -Be 239
    }

    It 'accepts an empty line' {
        $path = New-TempPath '.jsonl'
        Add-Utf8Line -Path $path -Line ''
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes.Length | Should -Be 1
        $bytes[0] | Should -Be 10
    }
}

Describe 'Read-Utf8Text' {

    It 'round-trips Swedish characters through Add-Utf8Line without loss' {
        $path = New-TempPath '.jsonl'
        Add-Utf8Line -Path $path -Line $script:Swedish
        Read-Utf8Text -Path $path | Should -Be ($script:Swedish + "`n")
    }

    It 'round-trips Swedish characters through Write-Utf8Text without loss' {
        $path = New-TempPath
        Write-Utf8Text -Path $path -Text $script:Swedish
        Read-Utf8Text -Path $path | Should -Be $script:Swedish
    }

    It 'preserves every character of the round-tripped Swedish text individually' {
        # Should -Be on the whole string would also pass if both sides were
        # mangled the same way; comparing code points cannot be fooled that way.
        $path = New-TempPath
        Write-Utf8Text -Path $path -Text $script:Swedish
        $back = Read-Utf8Text -Path $path
        $back.Length | Should -Be $script:Swedish.Length
        for ($i = 0; $i -lt $script:Swedish.Length; $i++) {
            [int]$back[$i] | Should -Be ([int]$script:Swedish[$i])
        }
    }

    It 'returns null for a file that does not exist' {
        # A missing history file is the normal state before the first dictation.
        # Null and empty string must stay distinguishable: the caller uses that
        # difference to tell "no file yet" from "file exists but is empty".
        $result = Read-Utf8Text -Path (Join-Path $TestDrive 'no-such-file.jsonl')
        ($null -eq $result) | Should -Be $true
    }

    It 'returns an empty string for an empty file' {
        $path = New-TempPath
        Write-Utf8Text -Path $path -Text ''
        Read-Utf8Text -Path $path | Should -Be ''
    }
}
