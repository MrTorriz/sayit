# DotEnv.Tests.ps1 - unit tests for Import-DotEnv and Get-Setting in
# win\lib\common.ps1.
#
# Every test writes its own .env into $TestDrive and passes the path explicitly.
# The developer's real .env is never read: it holds local paths and is not
# something a test suite has any business opening.
#
# Import-DotEnv deliberately parses the file instead of executing it, unlike the
# Linux side which sources it as bash. That makes the parser, rather than a
# shell, responsible for every edge case below.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\common.ps1')

    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:EnvCounter = 0

    # Each test gets its own file so nothing leaks between them.
    function New-DotEnv {
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
        $script:EnvCounter++
        $path = Join-Path $TestDrive ('dotenv-{0}.env' -f $script:EnvCounter)
        [System.IO.File]::WriteAllText($path, $Content, $script:Utf8)
        return $path
    }
}

Describe 'Import-DotEnv' {

    Context 'well-formed files' {

        It 'parses a plain KEY=VALUE line' {
            $cfg = Import-DotEnv -Path (New-DotEnv "MODEL_PATH=models\model.bin`n")
            $cfg['MODEL_PATH'] | Should -Be 'models\model.bin'
        }

        It 'parses several keys from one file' {
            $cfg = Import-DotEnv -Path (New-DotEnv "ONE=1`nTWO=2`nTHREE=3`n")
            $cfg.Count | Should -Be 3
            $cfg['TWO'] | Should -Be '2'
        }

        It 'ignores comment lines and blank lines' {
            $cfg = Import-DotEnv -Path (New-DotEnv "# a comment`n`n   `nKEY=value`n# KEY=overridden`n")
            $cfg.Count | Should -Be 1
            $cfg['KEY'] | Should -Be 'value'
        }

        It 'ignores a comment line that is indented' {
            $cfg = Import-DotEnv -Path (New-DotEnv "   # indented comment`nKEY=value`n")
            $cfg.Count | Should -Be 1
        }

        It 'strips one layer of surrounding double quotes' {
            $cfg = Import-DotEnv -Path (New-DotEnv "PROMPT=`"hello world`"`n")
            $cfg['PROMPT'] | Should -Be 'hello world'
        }

        It 'strips one layer of surrounding single quotes' {
            $cfg = Import-DotEnv -Path (New-DotEnv "PROMPT='hello world'`n")
            $cfg['PROMPT'] | Should -Be 'hello world'
        }

        It 'keeps quotes that are not a matching surrounding pair' {
            $cfg = Import-DotEnv -Path (New-DotEnv "PROMPT=`"unbalanced`n")
            $cfg['PROMPT'] | Should -Be '"unbalanced'
        }

        It 'trims whitespace around the key and the value' {
            $cfg = Import-DotEnv -Path (New-DotEnv "  KEY  =  value  `n")
            $cfg['KEY'] | Should -Be 'value'
        }

        It 'keeps everything after the first equals sign' {
            # Values legitimately contain equals signs, for instance a whisper
            # command line fragment. Splitting on every one would truncate them.
            $cfg = Import-DotEnv -Path (New-DotEnv "ARGS=--flag=1 --other=2`n")
            $cfg['ARGS'] | Should -Be '--flag=1 --other=2'
        }

        It 'accepts an explicitly empty value' {
            $cfg = Import-DotEnv -Path (New-DotEnv "EMPTY=`n")
            $cfg.ContainsKey('EMPTY') | Should -Be $true
            $cfg['EMPTY'] | Should -Be ''
        }
    }

    Context 'malformed input' {

        It 'ignores malformed lines instead of throwing' {
            # A hand-edited .env is the norm. A stray line must not stop the
            # dictation tool from starting.
            $content = "no equals sign at all`n" +
                       "=value with no key`n" +
                       "1BAD=leading digit is not a valid key`n" +
                       "has space=in key`n" +
                       "GOOD=kept`n"
            $path = New-DotEnv $content
            { Import-DotEnv -Path $path } | Should -Not -Throw
            $cfg = Import-DotEnv -Path $path
            $cfg['GOOD'] | Should -Be 'kept'
            $cfg.Count | Should -Be 1
        }

        It 'returns an empty result for a file that is entirely comments' {
            $cfg = Import-DotEnv -Path (New-DotEnv "# only`n# comments`n")
            $cfg.Count | Should -Be 0
        }
    }

    Context 'environment expansion' {

        It 'expands a %VAR% reference from the process environment' {
            # Settings are written with %LOCALAPPDATA% and friends so a .env can
            # be shared between machines without hard-coding a user profile path.
            $name = 'SAYIT_TEST_EXPAND_BASE'
            try {
                [Environment]::SetEnvironmentVariable($name, 'expanded-base', 'Process')
                $cfg = Import-DotEnv -Path (New-DotEnv "MODEL_PATH=%$name%\models\model.bin`n")
                $cfg['MODEL_PATH'] | Should -Be 'expanded-base\models\model.bin'
            } finally {
                [Environment]::SetEnvironmentVariable($name, $null, 'Process')
            }
        }

        It 'leaves an unknown %VAR% reference in place rather than blanking it' {
            $cfg = Import-DotEnv -Path (New-DotEnv "KEY=%SAYIT_TEST_NO_SUCH_VARIABLE%`n")
            $cfg['KEY'] | Should -Be '%SAYIT_TEST_NO_SUCH_VARIABLE%'
        }
    }

    Context 'missing file' {

        It 'returns an empty result rather than an error when the file does not exist' {
            $missing = Join-Path $TestDrive 'no-such-file.env'
            { Import-DotEnv -Path $missing } | Should -Not -Throw
            $cfg = Import-DotEnv -Path $missing
            $cfg | Should -BeOfType [hashtable]
            $cfg.Count | Should -Be 0
        }
    }
}

Describe 'Get-Setting' {

    BeforeAll {
        $script:VarName = 'SAYIT_TEST_SETTING'
    }

    AfterEach {
        [Environment]::SetEnvironmentVariable($script:VarName, $null, 'Process')
    }

    It 'returns the built-in default when nothing else supplies a value' {
        $cfg = @{}
        Get-Setting -Env $cfg -Name $script:VarName -Default 'fallback' | Should -Be 'fallback'
    }

    It 'prefers a value from .env over the built-in default' {
        $cfg = @{ $script:VarName = 'from-dotenv' }
        Get-Setting -Env $cfg -Name $script:VarName -Default 'fallback' | Should -Be 'from-dotenv'
    }

    It 'prefers the ambient process environment over .env' {
        # This is what makes an inline override on the command line work, and it
        # is what the bats suite relies on when it runs the Linux scripts.
        [Environment]::SetEnvironmentVariable($script:VarName, 'from-environment', 'Process')
        $cfg = @{ $script:VarName = 'from-dotenv' }
        Get-Setting -Env $cfg -Name $script:VarName -Default 'fallback' | Should -Be 'from-environment'
    }

    It 'falls through to the default when the .env value is empty' {
        # Matches the ${VAR:-default} behaviour the Linux scripts rely on: a key
        # left blank in .env means "use the default", not "use nothing".
        $cfg = @{ $script:VarName = '' }
        Get-Setting -Env $cfg -Name $script:VarName -Default 'fallback' | Should -Be 'fallback'
    }

    It 'falls through to .env when the ambient variable is set but empty' {
        [Environment]::SetEnvironmentVariable($script:VarName, '', 'Process')
        $cfg = @{ $script:VarName = 'from-dotenv' }
        Get-Setting -Env $cfg -Name $script:VarName -Default 'fallback' | Should -Be 'from-dotenv'
    }

    It 'returns an empty string when there is no value and no default' {
        $cfg = @{}
        Get-Setting -Env $cfg -Name $script:VarName | Should -Be ''
    }

    It 'is not confused by a different key being present in .env' {
        $cfg = @{ SAYIT_TEST_OTHER = 'unrelated' }
        Get-Setting -Env $cfg -Name $script:VarName -Default 'fallback' | Should -Be 'fallback'
    }
}
