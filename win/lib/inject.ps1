# inject.ps1 - shared text delivery, dot-sourced by sayit.ps1 and by
# sayit-inject.ps1.
#
# It lives here rather than only in sayit-inject.ps1 so a dictation does not have
# to start a second PowerShell just to deliver its result; that spawn cost about
# a second per dictation, a quarter of the whole release-to-text latency.
#
# Requires lib\common.ps1 to have been dot-sourced already.

$script:InjectorLoaded = $false

function Initialize-Injector {
    if ($script:InjectorLoaded) { return }
    if (-not ([System.Management.Automation.PSTypeName]'Sayit.Injector').Type) {
        Add-Type -AssemblyName System.Windows.Forms
        $libDir   = Join-Path $script:WinRoot 'lib'
        $trigger  = Read-Utf8Text -Path (Join-Path $libDir 'Trigger.cs')
        $injector = Read-Utf8Text -Path (Join-Path $libDir 'Injector.cs')
        if (-not $injector) { throw 'lib\Injector.cs not found' }
        # Injector references Trigger.InjectionSignature, so both compile together.
        Add-Type -TypeDefinition (Merge-CSharpSources -Sources @($trigger, $injector)) -Language CSharp `
                 -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing'
    }
    $script:InjectorLoaded = $true
}

# Returns 0 delivered, 1 nothing worked, 2 left on the clipboard for the user.
function Invoke-TextInjection {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [int]$Threshold = 100,
        [string]$Method = 'auto'
    )

    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    Initialize-Injector

    # Synthetic input cannot cross into a higher integrity level and the failure
    # is invisible to the caller, so detect it up front. The clipboard is not
    # blocked by UIPI, which makes leaving the text there an honest fallback
    # rather than a silent loss.
    if ([Sayit.Injector]::IsForegroundElevated()) {
        if ([Sayit.Injector]::SetClipboard($Text, 10)) {
            Write-Warning 'The focused window runs elevated; text is on the clipboard - press Ctrl+V.'
            return 2
        }
        Write-SayitError 'inject: elevated target and clipboard unavailable'
        return 1
    }

    $useClipboard = switch ($Method) {
        'clipboard' { $true }
        'type'      { $false }
        default     { $Text.Length -gt $Threshold }
    }

    if ($useClipboard) {
        if (-not [Sayit.Injector]::SetClipboard($Text, 10)) {
            Write-SayitError 'inject: clipboard stayed locked'
            return 1
        }
        Start-Sleep -Milliseconds 30
        if (-not [Sayit.Injector]::SendPasteChord()) {
            Write-SayitError 'inject: paste chord rejected'
            Write-Warning 'Paste was rejected; the text is on the clipboard - press Ctrl+V.'
            return 2
        }
        return 0
    }

    if (-not [Sayit.Injector]::TypeUnicode($Text, 512, 5)) {
        # Fall back to the clipboard rather than losing the text.
        if ([Sayit.Injector]::SetClipboard($Text, 10)) {
            Write-Warning 'Typing was rejected; the text is on the clipboard - press Ctrl+V.'
            return 2
        }
        Write-SayitError 'inject: typing rejected and clipboard unavailable'
        return 1
    }
    return 0
}
