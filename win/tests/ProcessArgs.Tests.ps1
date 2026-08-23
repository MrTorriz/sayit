# ProcessArgs.Tests.ps1 - unit tests for Format-ProcessArgument in
# win\lib\common.ps1.
#
# Start-Process concatenates -ArgumentList with spaces and quotes nothing, so
# an install path containing a space - "C:\Program Files\sayit" being the
# obvious one - splits into two arguments and the target never sees the file
# it was handed. Every path passed to Start-Process in win\ goes through this
# function first, so the escaping is checked here rather than by installing
# into a directory with a space in its name.
#
# NOT COVERED: the call sites themselves. Verifying those means spawning a
# recorder, and opening the microphone from a test suite is not acceptable in
# a dictation tool.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\common.ps1')
}

Describe 'Format-ProcessArgument' {
    Context 'values that need no quoting' {
        It 'leaves a path without spaces untouched' {
            Format-ProcessArgument 'C:\sayit\win\sayit-record.ps1' |
                Should -Be 'C:\sayit\win\sayit-record.ps1'
        }

        It 'leaves a bare switch untouched' {
            Format-ProcessArgument '-NoProfile' | Should -Be '-NoProfile'
        }

        It 'leaves an event name untouched' {
            Format-ProcessArgument 'Local\sayit-stop-1234' |
                Should -Be 'Local\sayit-stop-1234'
        }
    }

    Context 'values that need quoting' {
        It 'quotes a path containing a space' {
            Format-ProcessArgument 'C:\Program Files\sayit\win\sayit.ps1' |
                Should -Be '"C:\Program Files\sayit\win\sayit.ps1"'
        }

        It 'quotes a value containing a tab' {
            Format-ProcessArgument "a`tb" | Should -Be "`"a`tb`""
        }

        It 'represents an empty value as an empty argument rather than dropping it' {
            Format-ProcessArgument '' | Should -Be '""'
        }
    }

    Context 'command-line escaping rules' {
        It 'doubles trailing backslashes so they do not escape the closing quote' {
            Format-ProcessArgument 'C:\dir with space\' |
                Should -Be '"C:\dir with space\\"'
        }

        It 'leaves interior backslashes alone' {
            Format-ProcessArgument 'C:\a b\c\d' | Should -Be '"C:\a b\c\d"'
        }

        It 'escapes an embedded quote' {
            Format-ProcessArgument 'a "b" c' | Should -Be '"a \"b\" c"'
        }

        It 'doubles backslashes that precede an embedded quote' {
            Format-ProcessArgument 'a\\"b c' | Should -Be '"a\\\\\"b c"'
        }
    }
}
