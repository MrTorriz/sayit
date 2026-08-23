# Trigger.Tests.ps1 - unit tests for the pure parts of win\lib\Trigger.cs and
# win\lib\Injector.cs.
#
# Both files are compiled the way lib\inject.ps1 compiles them at runtime -
# merged, because Injector references Trigger.InjectionSignature - so a C# error
# in either one is caught here rather than the first time somebody presses the
# dictation key. They are written to C# 5 because Add-Type on Windows PowerShell
# 5.1 uses the in-box csc.exe; compiling them here is what keeps that honest.
#
# NOT COVERED: anything that installs a hook or synthesises input. Install,
# Reinstall and Uninstall arm and disarm a global low-level input hook, and
# TypeUnicode and SendPasteChord type into whatever window has focus. A test
# suite has no business doing either, so their contracts are checked by
# signature rather than by calling them. Configure and Drain touch nothing
# outside the class and are exercised directly.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\common.ps1')

    # A type can only be added once per process, and the runner puts every test
    # file in one process, so adding it twice would be a hard error.
    if (-not ('Sayit.Trigger' -as [type])) {
        $utf8    = New-Object System.Text.UTF8Encoding($false)
        $libDir  = (Resolve-Path (Join-Path $PSScriptRoot '..\lib')).Path
        $trigger = [System.IO.File]::ReadAllText((Join-Path $libDir 'Trigger.cs'), $utf8)
        $injector = [System.IO.File]::ReadAllText((Join-Path $libDir 'Injector.cs'), $utf8)
        Add-Type -TypeDefinition (Merge-CSharpSources -Sources @($trigger, $injector)) `
                 -Language CSharp -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing'
    }
}

Describe 'Trigger.cs' {

    Context 'compilation' {

        It 'compiles together with Injector.cs and exposes both types' {
            ('Sayit.Trigger' -as [type])  | Should -Not -BeNullOrEmpty
            ('Sayit.Injector' -as [type]) | Should -Not -BeNullOrEmpty
        }

        It 'exposes the nested TriggerEvent type with the fields the pump reads' {
            # sayit-trigger.ps1 reads all five off each drained event, so a
            # renamed field would stop the trigger silently under strict mode.
            $t = 'Sayit.Trigger+TriggerEvent' -as [type]
            $t | Should -Not -BeNullOrEmpty
            $names = $t.GetFields() | ForEach-Object { $_.Name }
            foreach ($field in @('Kind', 'Button', 'Down', 'Injected', 'Raw')) {
                $names | Should -Contain $field
            }
        }

        It 'exposes InjectionSignature, which Injector.cs stamps on its input' {
            # The two files are compiled together for this constant alone: it is
            # how the trigger hook tells sayit's own typing from real input.
            [Sayit.Trigger]::InjectionSignature | Should -Be 0x5A17
        }
    }

    Context 'hook installation contract' {

        # Not called here - installing a second global hook from a test suite is
        # not acceptable. The signature is the contract: SetWindowsHookEx failing
        # is otherwise completely silent, and sayit-trigger.ps1 documents exit
        # code 1 for it, which it can only produce if these report failure.

        It 'declares Install as returning a Boolean' {
            [Sayit.Trigger].GetMethod('Install').ReturnType.FullName |
                Should -Be 'System.Boolean'
        }

        It 'declares Reinstall as returning a Boolean' {
            [Sayit.Trigger].GetMethod('Reinstall').ReturnType.FullName |
                Should -Be 'System.Boolean'
        }
    }

    Context 'Configure' {

        It 'accepts a mouse button name without throwing' {
            { [Sayit.Trigger]::Configure('XBUTTON2', $true, $false) } | Should -Not -Throw
        }

        It 'accepts a VK binding, which is how a keyboard key is bound' {
            # .env.example documents VK124 for F13. Parsing it wrong binds nothing
            # and the trigger then never fires.
            { [Sayit.Trigger]::Configure('VK124', $true, $false) } | Should -Not -Throw
        }

        It 'accepts a null button without throwing' {
            { [Sayit.Trigger]::Configure($null, $true, $false) } | Should -Not -Throw
        }
    }

    Context 'Drain' {

        It 'returns an empty array rather than null when nothing was observed' {
            # The pump iterates the result directly, with no null check.
            [Sayit.Trigger]::Configure('XBUTTON2', $true, $false)
            $events = [Sayit.Trigger]::Drain()
            ($null -eq $events) | Should -Be $false
            $events.Count | Should -Be 0
        }
    }
}

Describe 'Injector.cs' {

    Context 'integrity level detection' {

        It 'reports whether the foreground window is elevated without throwing' {
            # Synthetic input cannot cross into a higher integrity level and the
            # failure is invisible, so this check is the only thing standing
            # between the user and text that vanishes on delivery.
            { [Sayit.Injector]::IsForegroundElevated() } | Should -Not -Throw
        }

        It 'returns a Boolean' {
            [Sayit.Injector]::IsForegroundElevated() | Should -BeOfType [bool]
        }

        It 'opens process tokens with a right that survives an integrity boundary' {
            # PROCESS_QUERY_INFORMATION (0x0400) is refused on a process at a
            # higher integrity level, so using it made IsForegroundElevated
            # answer "not elevated" for exactly the windows it exists to catch.
            # This reads the source because the alternative needs an elevated
            # process to point at, which a test suite cannot conjure up.
            # PROCESS_QUERY_LIMITED_INFORMATION (0x1000) is granted there, and
            # OpenProcessToken accepts it from Vista onwards.
            $source = [System.IO.File]::ReadAllText(
                (Join-Path $PSScriptRoot '..\lib\Injector.cs'),
                (New-Object System.Text.UTF8Encoding($false)))
            $source | Should -Match 'OpenProcess\(0x1000'
            $source | Should -Not -Match 'OpenProcess\(0x0400'
        }
    }

    Context 'clipboard fallback' {

        It 'declares the threshold the length-based method choice uses' {
            [Sayit.Injector]::ClipboardThreshold | Should -Be 100
        }
    }
}
