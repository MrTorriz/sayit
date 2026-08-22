# Wordlist.Tests.ps1 - unit tests for win\sayit-wordlist.ps1.
#
# Pure text transformation: no model, no microphone, no .env is ever read.
# Every test passes -WordlistPath explicitly, so the script never falls back to
# Import-DotEnv and can never pick up the developer's real configuration.
#
# These tests pin the same contract as tests/wordlist.bats on the Linux side.
# The two implementations share the wordlist file format, so a divergence here
# means the same wordlist.tsv behaves differently on the two platforms, which is
# exactly the class of regression this file exists to catch.
#
# NOTE: this file is stored as UTF-8 WITH a byte order mark. Windows PowerShell
# 5.1 decodes a BOM-less script file using the ANSI code page, which would turn
# the Swedish literals below into mojibake and make the Unicode tests assert
# something other than what they read as.

BeforeAll {
    $script:WordlistScript = (Resolve-Path (Join-Path $PSScriptRoot '..\sayit-wordlist.ps1')).Path
    $script:Utf8           = New-Object System.Text.UTF8Encoding($false)

    $script:WordlistFile = Join-Path $TestDrive 'wordlist.tsv'
    $script:InFile       = Join-Path $TestDrive 'stdin.txt'
    $script:OutFile      = Join-Path $TestDrive 'stdout.txt'
    $script:Harness      = Join-Path $TestDrive 'Invoke-WordlistHarness.ps1'

    # The script under test reads [Console]::In and writes [Console]::Out. Piping
    # through a real console would route the bytes via the console code page,
    # which on Windows PowerShell 5.1 is not UTF-8 and would corrupt every
    # non-ASCII character before the script ever saw it. The harness swaps the
    # console streams for UTF-8 file streams instead, so the test measures the
    # transformation and not the terminal.
    $harnessSource = @'
param(
    [Parameter(Mandatory)][string]$ScriptPath,
    [Parameter(Mandatory)][AllowEmptyString()][string]$WordlistPath,
    [Parameter(Mandatory)][string]$InPath,
    [Parameter(Mandatory)][string]$OutPath
)

$enc    = New-Object System.Text.UTF8Encoding($false)
$reader = New-Object System.IO.StreamReader($InPath, $enc)
$writer = New-Object System.IO.StreamWriter($OutPath, $false, $enc)
[Console]::SetIn($reader)
[Console]::SetOut($writer)

# The script under test never calls exit, so seed the variable and report it
# unchanged; an unhandled terminating error makes powershell.exe exit non-zero
# on its own, which is what the "exits 0" assertions rely on.
$global:LASTEXITCODE = 0
try {
    & $ScriptPath -WordlistPath $WordlistPath
} finally {
    $writer.Flush()
    $writer.Close()
    $reader.Close()
}
exit $LASTEXITCODE
'@
    [System.IO.File]::WriteAllText($script:Harness, $harnessSource, $script:Utf8)

    # Write a wordlist with LF line endings, matching the file the Linux side
    # produces and consumes.
    function Set-Wordlist {
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
        [System.IO.File]::WriteAllText($script:WordlistFile, $Content, $script:Utf8)
    }

    # Run the script in a child Windows PowerShell so the exit code is real.
    function Invoke-Wordlist {
        param(
            [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
            [AllowEmptyString()][string]$WordlistPath = $script:WordlistFile
        )
        [System.IO.File]::WriteAllText($script:InFile, $Text, $script:Utf8)
        if (Test-Path -LiteralPath $script:OutFile) {
            Remove-Item -LiteralPath $script:OutFile -Force
        }

        $null = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $script:Harness `
            -ScriptPath $script:WordlistScript `
            -WordlistPath $WordlistPath `
            -InPath $script:InFile `
            -OutPath $script:OutFile
        $code = $LASTEXITCODE

        $text = ''
        if (Test-Path -LiteralPath $script:OutFile) {
            $text = [System.IO.File]::ReadAllText($script:OutFile, $script:Utf8)
        }
        return [pscustomobject]@{ ExitCode = $code; Output = $text }
    }
}

Describe 'sayit-wordlist' {

    Context 'basic replacement' {

        It 'replaces a simple rule' {
            Set-Wordlist "get hub`tGitHub`n"
            $r = Invoke-Wordlist -Text 'pushed to get hub today'
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Be 'pushed to GitHub today'
        }

        It 'replaces every occurrence, not just the first' {
            Set-Wordlist "cat`tdog`n"
            (Invoke-Wordlist -Text 'cat sees cat').Output | Should -Be 'dog sees dog'
        }

        It 'leaves text alone when no rule matches' {
            Set-Wordlist "get hub`tGitHub`n"
            (Invoke-Wordlist -Text 'nothing to see here').Output | Should -Be 'nothing to see here'
        }

        It 'passes an empty input through as empty output' {
            Set-Wordlist "cat`tdog`n"
            $r = Invoke-Wordlist -Text ''
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Be ''
        }
    }

    Context 'file format' {

        It 'splits a row on the first tab only, so a replacement may contain tabs' {
            # A replacement holding tabs is how a rule expands one dictated word
            # into a tab-separated snippet. Splitting on every tab would silently
            # truncate it at the first one.
            Set-Wordlist "col`ta`tb`n"
            (Invoke-Wordlist -Text 'col').Output | Should -Be "a`tb"
        }

        It 'ignores comment lines and blank lines' {
            Set-Wordlist "# cat`tthis is only a comment`n`ncat`tdog`n"
            (Invoke-Wordlist -Text 'a cat appears').Output | Should -Be 'a dog appears'
        }

        It 'skips a row that has no tab at all' {
            Set-Wordlist "justoneword`ncat`tdog`n"
            (Invoke-Wordlist -Text 'a cat and justoneword').Output | Should -Be 'a dog and justoneword'
        }

        It 'skips a row whose original is empty' {
            # An empty original would compile to a pattern that matches at every
            # word boundary, injecting the replacement throughout the text.
            Set-Wordlist "`tINJECTED`ncat`tdog`n"
            $out = (Invoke-Wordlist -Text 'a cat appears').Output
            $out | Should -Be 'a dog appears'
            $out | Should -Not -Match 'INJECTED'
        }

        It 'skips a row whose replacement is empty' {
            # Deleting words is not what an empty second column means; such a row
            # is a typo and must not silently erase text.
            Set-Wordlist "cat`t`n"
            (Invoke-Wordlist -Text 'the cat sat').Output | Should -Be 'the cat sat'
        }

        It 'reads the wordlist as UTF-8 rather than the ANSI code page' {
            Set-Wordlist "ratta`trätta`n"
            (Invoke-Wordlist -Text 'vi ska ratta detta').Output | Should -Be 'vi ska rätta detta'
        }
    }

    Context 'rule ordering' {

        It 'lets the longest original win regardless of the order in the file' {
            # "hub" appears first in the file but must not consume the "hub" of
            # "get hub", otherwise a multi-word rule can never be written after a
            # single-word one.
            Set-Wordlist "hub`tnav`nget hub`tGitHub`n"
            (Invoke-Wordlist -Text 'open get hub').Output | Should -Be 'open GitHub'
        }

        It 'lets the longest original win when the multi-word rule comes first' {
            Set-Wordlist "get hub`tGitHub`nhub`tnav`n"
            (Invoke-Wordlist -Text 'open get hub').Output | Should -Be 'open GitHub'
        }

        It 'applies rules sequentially, so a replacement can be matched by a later shorter rule' {
            # Rules run one after another over the whole text, longest original
            # first. The output of the "get hub" rule is therefore still visible
            # to the shorter "forge" rule. Documented behaviour, not an accident.
            Set-Wordlist "get hub`tcode forge`nforge`tGitHub`n"
            $out = (Invoke-Wordlist -Text 'open get hub').Output
            $out | Should -Be 'open code GitHub'
            $out | Should -Not -Match 'forge'
        }
    }

    Context 'matching semantics' {

        It 'matches case-insensitively' {
            Set-Wordlist "get hub`tGitHub`n"
            (Invoke-Wordlist -Text 'Get Hub is down').Output | Should -Be 'GitHub is down'
        }

        It 'respects word boundaries and does not match inside a longer word' {
            # Whisper output is full of words that contain shorter words. Without
            # boundaries a rule for "cat" would rewrite "category".
            Set-Wordlist "cat`tdog`n"
            (Invoke-Wordlist -Text 'category cat concatenate').Output | Should -Be 'category dog concatenate'
        }

        It 'treats Swedish letters as word characters, so "på" does not match inside "påse"' {
            # "å" must count as a word character for the boundary to sit between
            # "på" and "påse". If the regex engine treated it as punctuation the
            # rule would fire inside every word beginning with "på".
            Set-Wordlist "på`tON`n"
            (Invoke-Wordlist -Text 'på påse').Output | Should -Be 'ON påse'
        }

        It 'treats an original as a literal string, not as a regular expression' {
            # "2+2" as a regex would mean "one or more 2 followed by 2". The rule
            # must match the characters the user actually dictated.
            Set-Wordlist "2+2`t4`n"
            (Invoke-Wordlist -Text 'what is 2+2 now').Output | Should -Be 'what is 4 now'
        }

        It 'does not treat a dollar sign in the replacement as a capture reference' {
            # .NET Regex.Replace expands $1 and $& in a replacement string. The
            # replacement here is user data and must be inserted verbatim.
            Set-Wordlist "dollar`t`$1 and `$&`n"
            (Invoke-Wordlist -Text 'a dollar here').Output | Should -Be 'a $1 and $& here'
        }
    }

    Context 'output shape' {

        It 'writes no trailing newline' {
            # The caller injects this text straight into the focused window. A
            # stray newline there submits a form or sends a chat message.
            Set-Wordlist "cat`tdog`n"
            $out = (Invoke-Wordlist -Text 'the cat').Output
            $out | Should -Be 'the dog'
            $out.EndsWith("`n") | Should -Be $false
            $out.EndsWith("`r") | Should -Be $false
        }

        It 'preserves an interior newline in the input' {
            Set-Wordlist "cat`tdog`n"
            (Invoke-Wordlist -Text "cat`ncat").Output | Should -Be "dog`ndog"
        }
    }

    Context 'missing wordlist' {

        It 'passes text through unchanged and exits 0 when the wordlist does not exist' {
            # A missing wordlist is the normal state of a fresh install. It must
            # never take a dictation down.
            $missing = Join-Path $TestDrive 'no-such-wordlist.tsv'
            $r = Invoke-Wordlist -Text 'untouched text' -WordlistPath $missing
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Be 'untouched text'
        }

        It 'passes non-ASCII text through unchanged when the wordlist does not exist' {
            $missing = Join-Path $TestDrive 'no-such-wordlist.tsv'
            $r = Invoke-Wordlist -Text 'räksmörgås på Öland' -WordlistPath $missing
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Be 'räksmörgås på Öland'
        }
    }
}
