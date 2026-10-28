BeforeAll {
    . "$PSScriptRoot\..\lib\common.ps1"
    . "$PSScriptRoot\..\lib\engine.ps1"
}

Describe 'Windows engine selection' {
    BeforeEach {
        $script:ConfigDir = Join-Path $TestDrive 'config'
        $script:RunDir = Join-Path $TestDrive 'run'
        New-Item -ItemType Directory -Force $script:ConfigDir,$script:RunDir | Out-Null
        Remove-Item (Join-Path $script:ConfigDir 'engine-mode') -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $script:RunDir 'sayit.session') -ErrorAction SilentlyContinue
    }
    It 'defaults to the existing engine and rejects corrupt selections' {
        Get-SayitEngineMode | Should -Be 'accurate'
        Write-Utf8Text (Join-Path $script:ConfigDir 'engine-mode') 'wrong'
        { Get-SayitEngineMode } | Should -Throw '*Invalid engine-mode*'
    }
    It 'requires ready=true for Turbo, not just an open port' {
        Test-SayitEngineHealth ([pscustomobject]@{engine='openvino-turbo';ready=$true}) 'fast' | Should -BeTrue
        Test-SayitEngineHealth ([pscustomobject]@{engine='openvino-turbo';ready=$false}) 'fast' | Should -BeFalse
        Test-SayitEngineHealth ([pscustomobject]@{status='ok'}) 'fast' | Should -BeFalse
        Test-SayitEngineHealth ([pscustomobject]@{status='ok'}) 'accurate' | Should -BeTrue
        Test-SayitEngineHealth ([pscustomobject]@{engine='other'}) 'accurate' | Should -BeFalse
        Test-SayitEngineHealth $null 'fast' | Should -BeFalse
    }
    It 'allows concurrent dictations but excludes engine switches' {
        $first = Open-SayitEngineGate
        $second = Open-SayitEngineGate
        try { { Open-SayitEngineGate -Exclusive } | Should -Throw '*busy*' }
        finally { $first.Dispose(); $second.Dispose() }
        $exclusive = Open-SayitEngineGate -Exclusive
        try { { Open-SayitEngineGate } | Should -Throw '*busy*' }
        finally { $exclusive.Dispose() }
    }
    It 'refuses switching during a recording' {
        Write-Utf8Text (Join-Path $script:RunDir 'sayit.session') 'recording'
        { Set-SayitEngineMode fast @{} } | Should -Throw '*Finish or cancel*'
    }
    It 'restores the old engine and selection when startup fails' {
        Mock Get-SayitEngineLaunch { param($Config,$Mode) [pscustomobject]@{Mode=$Mode;Port=12345} }
        Mock Assert-SayitEngineLaunch {}
        Mock Stop-SayitEngine {}
        Mock Start-SayitEngine { param($Launch) if ($Launch.Mode -eq 'fast') { throw 'GPU unavailable' } }
        { Set-SayitEngineMode fast @{} } | Should -Throw '*previous engine restored*'
        Get-SayitEngineMode | Should -Be 'accurate'
        Should -Invoke Start-SayitEngine -Times 1 -ParameterFilter { $Launch.Mode -eq 'accurate' }
        $gate = Open-SayitEngineGate -Exclusive
        $gate.Dispose()
    }
    It 'persists a healthy switch and replaces an existing selection' {
        Mock Get-SayitEngineLaunch { param($Config,$Mode) [pscustomobject]@{Mode=$Mode;Port=12345} }
        Mock Get-SayitEngineHealth { $null }
        Mock Assert-SayitEngineLaunch {}
        Mock Stop-SayitEngine {}
        Mock Start-SayitEngine {}
        Set-SayitEngineMode fast @{}
        Get-SayitEngineMode | Should -Be 'fast'
        Set-SayitEngineMode accurate @{}
        Get-SayitEngineMode | Should -Be 'accurate'
    }
}
