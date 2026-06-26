BeforeAll {
    Remove-Module PSAppDeployToolkit -Force -ErrorAction SilentlyContinue
    Import-Module "$PSScriptRoot\..\..\..\PSAppDeployToolkit\PSAppDeployToolkit.psd1" -Force
}
Describe 'Remove-ADTIniValue' {
    BeforeAll {
        # Use [System.IO.File]::WriteAllText with explicit CRLF line endings instead of Set-Content,
        # because Set-Content behaviour varies across environments (e.g. self-hosted runners with
        # git autocrlf=false may produce LF-only files).  The INI functions always write CRLF, so
        # the baseline file must also use CRLF for -FileContentMatchMultiline assertions to pass.
        # BeforeEach (not BeforeAll) ensures a fresh file for every test since Remove-ADTIniValue mutates it.
        $IniPath = "$TestDrive\IniFile.ini"
        [System.IO.File]::WriteAllText($IniPath, "[MySection]`r`nMyKey=MyValue`r`nMyOtherKey=MyOtherValue`r`n", [System.Text.Encoding]::ASCII)

        # Mock Write-ADTLogEntry due to its expense when running via Pester.
        Mock -ModuleName PSAppDeployToolkit Write-ADTLogEntry { }
    }

    Context 'Functionality' {
        It 'Should not throw when removing a non-existent Key' {
            { Remove-ADTIniValue -FilePath $IniPath -Section 'MySection' -Key 'MissingKey' } | Should -Not -Throw
            $IniPath | Should -FileContentMatchMultiline 'MyKey=MyValue'
            $IniPath | Should -FileContentMatchMultiline 'MyOtherKey=MyOtherValue'
        }
        It 'Should remove a Key' {
            Remove-ADTIniValue -FilePath $IniPath -Section 'MySection' -Key 'MyKey'
            $IniPath | Should -FileContentMatchMultiline '\[MySection\]\r\nMyOtherKey=MyOtherValue\r\n'
            $IniPath  | Should -Not -FileContentMatchMultiline 'MyKey='
        }
    }

    Context 'Input Validation' {
        It 'Should verify that FilePath is not null, empty or whitespace' {
            $shouldParams = @{
                Throw = $true
                ExceptionType = [System.Management.Automation.ParameterBindingException]
                ErrorId = 'ParameterArgumentValidationError,Remove-ADTIniValue'
            }
            { Remove-ADTIniValue -FilePath $null -Section 'Anything' -Key 'Anything' } | Should @shouldParams
            { Remove-ADTIniValue -FilePath '' -Section 'Anything' -Key 'Anything' } | Should @shouldParams
            { Remove-ADTIniValue -FilePath " `f`n`r`t`v" -Section 'Anything' -Key 'Anything' } | Should @shouldParams
        }
        It 'Should verify that FilePath exists' {
            { Remove-ADTIniValue -FilePath "$TestDrive\DoesNotExist.ini" -Section 'Anything' -Key 'Anything' } | Should -Throw -ExceptionType ([System.IO.FileNotFoundException]) -ErrorId 'LiteralPathNotFound,Remove-ADTIniValue'
        }
        It 'Should verify that Section is not null, empty or whitespace' {
            $shouldParams = @{
                Throw = $true
                ExceptionType = [System.Management.Automation.ParameterBindingException]
                ErrorId = 'ParameterArgumentValidationError,Remove-ADTIniValue'
            }
            { Remove-ADTIniValue -FilePath $IniPath -Section $null -Key 'Anything' } | Should @shouldParams
            { Remove-ADTIniValue -FilePath $IniPath -Section '' -Key 'Anything' } | Should @shouldParams
            { Remove-ADTIniValue -FilePath $IniPath -Section " `f`n`r`t`v" -Key 'Anything' } | Should @shouldParams

        }
        It 'Should verify that Key is not null, empty or whitespace' {
            $shouldParams = @{
                Throw = $true
                ExceptionType = [System.Management.Automation.ParameterBindingException]
                ErrorId = 'ParameterArgumentValidationError,Remove-ADTIniValue'
            }
            { Remove-ADTIniValue -FilePath $IniPath -Section 'MySection' -Key $null } | Should @shouldParams
            { Remove-ADTIniValue -FilePath $IniPath -Section 'MySection' -Key '' } | Should @shouldParams
            { Remove-ADTIniValue -FilePath $IniPath -Section 'MySection' -Key " `f`n`r`t`v" } | Should @shouldParams
        }
    }
}
