function Invoke-ADTTemplateRunner {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrWhiteSpace()]
        [System.String]$TemplatefilePath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrWhiteSpace()]
        [System.String]$DestinationPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.Collections.Generic.List[System.String]]$Files,

        [Parameter(Mandatory = $false)]
        [ValidateNotNull()]
        [System.Collections.Generic.List[System.String]]$SupportFiles

    )

    if (!(Test-Path -LiteralPath $TemplatefilePath -PathType Leaf))
    {
        throw "Template file was not found: [$TemplatefilePath]"
    }

    if (![System.String]::Equals([System.IO.Path]::GetExtension($TemplatefilePath), '.ps1', [System.StringComparison]::OrdinalIgnoreCase))
    {
        throw "TemplatefilePath must point to a .ps1 file. Current value: [$TemplatefilePath]"
    }

    # Dot-source the template parameter file into local scope so declared variables are available.
    . $TemplatefilePath

    $params = $null

    if (Get-Variable -Name NewADTTemplateParameters -Scope Local -ErrorAction Ignore)
    {
        $params = (Get-Variable -Name NewADTTemplateParameters -Scope Local).Value
    }

    if ($null -eq $params)
    {
        # Fallback: if exactly one hashtable variable exists after loading, treat it as template params.
        $candidateParams = @(Get-Variable -Scope Local | Where-Object { $_.Value -is [System.Collections.IDictionary] })
        if ($candidateParams.Count -eq 1)
        {
            $params = $candidateParams[0].Value
        }
    }

    if ($null -eq $params -or $params -isnot [System.Collections.IDictionary])
    {
        throw "Unable to resolve template parameters from [$TemplatefilePath]. Expected variable [\$NewADTTemplateParameters] of type hashtable/dictionary."
    }

    if ($params.Contains('Destination'))
    {
        $params['Destination'] = $DestinationPath
    }
    else
    {
        $params.Add('Destination', $DestinationPath)
    }

    $templateFiles = @($Files)
    if ($params.Contains('Files'))
    {
        $params['Files'] = $templateFiles
    }
    else
    {
        $params.Add('Files', $templateFiles)
    }

    if ($PSBoundParameters.ContainsKey('SupportFiles') -and $null -ne $SupportFiles -and $SupportFiles.Count -gt 0)
    {
        if ($params.Contains('SupportFiles'))
        {
            $params['SupportFiles'] = @($SupportFiles)
        }
        else
        {
            $params.Add('SupportFiles', @($SupportFiles))
        }
    }

    New-ADTTemplate @params
     
}