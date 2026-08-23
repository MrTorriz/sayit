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

    # The script under test decodes stdin and encodes stdout itself. Driving it
    # through a real child process with real redirection is therefore the whole
    # point: a harness that swapped [Console]::In and [Console]::Out for UTF-8
    # streams would measure the transformation and nothing else, and would pass
    # just as happily if the script mangled every non-ASCII byte on the way in
    # and on the way out.
    #
    # A child started this way gets the OEM code page (850 on a Swedish install)
    # for both directions, which is exactly what the script meets in normal use,
    # and it leaves the code page of the console running the suite alone.
    function Set-Wordlist {
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
        [System.IO.File]::WriteAllText($script:WordlistFile, $Content, $script:Utf8)
    }

    # Run the script in a child Windows PowerShell so the exit code is real.
    # Bytes go in and come out raw: any decoding here would hide the defect.
    function Invoke-Wordlist {
        param(
            [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
            [AllowEmptyString()][string]$WordlistPath = $script:WordlistFile
        )

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName  = 'powershell.exe'
        $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -WordlistPath "{1}"' -f `
                         $script:WordlistScript, $WordlistPath
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardInput  = $true
        $psi.RedirectStandardOutput = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        $inBytes = $script:Utf8.GetBytes($Text)
        $proc.StandardInput.BaseStream.Write($inBytes, 0, $inBytes.Length)
        $proc.StandardInput.BaseStream.Flush()
        $proc.StandardInput.Close()

        $buffer = New-Object System.IO.MemoryStream
        $proc.StandardOutput.BaseStream.CopyTo($buffer)
        $proc.WaitForExit()

        $out = $script:Utf8.GetString($buffer.ToArray())
        $code = $proc.ExitCode
        $proc.Dispose()
        $buffer.Dispose()
        return [pscustomobject]@{ ExitCode = $code; Output = $out }
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
