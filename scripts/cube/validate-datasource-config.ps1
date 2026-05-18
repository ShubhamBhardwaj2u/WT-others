param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$BimPath,

    [Parameter(Mandatory = $true, Position = 1)]
    [ValidateSet("DEV", "UAT", "PROD")]
    [string]$Environment,

    [Parameter(Mandatory = $true, Position = 2)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$DatasourcesConfigFile,

    [Parameter(Mandatory = $false)]
    [switch]$StrictMode
)

$ErrorActionPreference = "Stop"
$script:ValidationErrors = @()
$script:ValidationWarnings = @()

$Colors = @{
    Red      = [ConsoleColor]::Red
    Yellow   = [ConsoleColor]::Yellow
    Green    = [ConsoleColor]::Green
    Cyan     = [ConsoleColor]::Cyan
    White    = [ConsoleColor]::White
    DarkGray = [ConsoleColor]::DarkGray
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = $Colors.White

    switch ($Level) {
        "ERROR"   { $color = $Colors.Red }
        "WARNING" { $color = $Colors.Yellow }
        "SUCCESS" { $color = $Colors.Green }
        "INFO"    { $color = $Colors.Cyan }
        "DEBUG"   { $color = $Colors.DarkGray }
    }

    Write-Host "[$Level] $Message" -ForegroundColor $color
}

function Write-Section {
    param([string]$Title)

    Write-Host ""
    Write-Host "============================================================"
    Write-Host " $Title"
    Write-Host "============================================================"
}

function Add-ValidationError {
    param([string]$Message)

    $script:ValidationErrors += $Message
    Write-Log "ERROR: $Message" -Level "ERROR"
}

function Add-ValidationWarning {
    param([string]$Message)

    $script:ValidationWarnings += $Message
    Write-Log "WARNING: $Message" -Level "WARNING"
}

function Initialize-YamlModule {
    Write-Section "Step 1: YAML Module Initialization"

    try {
        if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
            Install-Module -Name powershell-yaml -Scope CurrentUser -Force -ErrorAction Stop
            Write-Log "Installed powershell-yaml module" -Level "SUCCESS"
        }

        Import-Module -Name powershell-yaml -Force -ErrorAction Stop
        Write-Log "Loaded powershell-yaml module" -Level "SUCCESS"
        return $true
    }
    catch {
        Add-ValidationError "Failed to initialize powershell-yaml module: $($_.Exception.Message)"
        return $false
    }
}

function Read-BimModel {
    param([string]$Path)

    Write-Section "Step 2: BIM File Validation"

    try {
        $json = Get-Content $Path -Raw -Encoding UTF8
        $bim = $json | ConvertFrom-Json -ErrorAction Stop

        if (-not $bim.name) {
            Add-ValidationError "BIM root property 'name' is missing."
            return $null
        }

        if (-not $bim.model) {
            Add-ValidationError "BIM root property 'model' is missing."
            return $null
        }

        if (-not $bim.model.dataSources -or $bim.model.dataSources.Count -eq 0) {
            Add-ValidationError "BIM model has no datasources defined."
            return $null
        }

        Write-Log "BIM file validated successfully" "SUCCESS"
        Write-Log "Model Name: $($bim.name)" "INFO"
        Write-Log "Datasources found in BIM: $($bim.model.dataSources.Count)" "INFO"

        return $bim
    }
    catch {
        Add-ValidationError "Failed to read or parse BIM file: $($_.Exception.Message)"
        return $null
    }
}

function Read-DatasourceConfig {
    param(
        [string]$Path,
        [string]$ExpectedEnvironment
    )

    Write-Section "Step 3: Datasource YAML Validation"

    try {
        $yaml = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Yaml

        if (-not $yaml) {
            Add-ValidationError "Datasource YAML file is empty or invalid."
            return $null
        }

        if (-not $yaml.environment) {
            Add-ValidationError "Datasource YAML is missing 'environment' property."
            return $null
        }

        if ($yaml.environment.ToString().ToUpper() -ne $ExpectedEnvironment.ToUpper()) {
            Add-ValidationError "Environment mismatch. YAML has '$($yaml.environment)', expected '$ExpectedEnvironment'."
            return $null
        }

        if (-not $yaml.datasources -or $yaml.datasources.Count -eq 0) {
            Add-ValidationError "Datasource YAML has no 'datasources' entries."
            return $null
        }

        foreach ($ds in $yaml.datasources) {
            if ([string]::IsNullOrWhiteSpace($ds.name)) {
                Add-ValidationError "Datasource entry is missing 'name'."
            }

            if ([string]::IsNullOrWhiteSpace($ds.server)) {
                Add-ValidationError "Datasource '$($ds.name)' is missing 'server'."
            }

            if ([string]::IsNullOrWhiteSpace($ds.database)) {
                Add-ValidationError "Datasource '$($ds.name)' is missing 'database'."
            }
        }

        $names = @($yaml.datasources | ForEach-Object { $_.name.Trim().ToLower() })
        $duplicates = $names | Group-Object | Where-Object { $_.Count -gt 1 }

        if ($duplicates) {
            Add-ValidationError "Duplicate datasource names found in YAML: $($duplicates.Name -join ', ')"
        }

        if ($script:ValidationErrors.Count -gt 0) {
            return $null
        }

        Write-Log "Datasource YAML validated successfully" -Level "SUCCESS"
        Write-Log "Environment: $($yaml.environment)" -Level "INFO"
        Write-Log "Datasources found in YAML: $($yaml.datasources.Count)" -Level "INFO"

        return $yaml
    }
    catch {
        Add-ValidationError "Failed to read or parse datasource YAML: $($_.Exception.Message)"
        return $null
    }
}

function Test-DatasourceSync {
    param(
        [object]$Bim,
        [object]$Yaml
    )

    Write-Section "Step 4: Datasource Sync Validation"

    $bimDatasourceNames = @($Bim.model.dataSources | ForEach-Object { $_.name.Trim() })
    $yamlDatasourceNames = @($Yaml.datasources | ForEach-Object { $_.name.Trim() })

    $bimDatasourceNamesLower = @($bimDatasourceNames | ForEach-Object { $_.ToLower() })
    $yamlDatasourceNamesLower = @($yamlDatasourceNames | ForEach-Object { $_.ToLower() })

    foreach ($yamlName in $yamlDatasourceNames) {
        if ($yamlName.ToLower() -notin $bimDatasourceNamesLower) {
            Add-ValidationError "Datasource defined in YAML but missing in BIM: $yamlName"
        }
    }

    foreach ($bimName in $bimDatasourceNames) {
        if ($bimName.ToLower() -notin $yamlDatasourceNamesLower) {
            Add-ValidationError "Datasource exists in BIM but missing in YAML: $bimName"
        }
    }

    if ($script:ValidationErrors.Count -gt 0) {
        return $false
    }

    Write-Log "Datasource names are in sync between BIM and YAML" -Level "SUCCESS"
    return $true
}

function Test-DatasourceConfigValues {
    param([object]$Yaml)

    Write-Section "Step 5: Datasource Value Validation"

    foreach ($ds in $Yaml.datasources) {
        Write-Log "Validating datasource: $($ds.name)" -Level "INFO"

        if ($ds.server -match "localhost|127\.0\.0\.1") {
            Add-ValidationError "Datasource '$($ds.name)' points to local server '$($ds.server)'. This is not allowed for shared environments."
        }

        if ($Environment -eq "PROD" -and $ds.server -match "DEV|UAT|DWD|UWD") {
            Add-ValidationWarning "PROD datasource '$($ds.name)' server value looks non-production: $($ds.server)"
        }

        if ($Environment -eq "UAT" -and $ds.server -match "DEV|DWD") {
            Add-ValidationWarning "UAT datasource '$($ds.name)' server value looks development-like: $($ds.server)"
        }

        Write-Log "Datasource '$($ds.name)' validated" -Level "SUCCESS"
    }

    return $true
}

Write-Section "SSAS Datasource Configuration Validation"

Write-Log "BIM Path: $BimPath" -Level "INFO"
Write-Log "Datasource Config File: $DatasourcesConfigFile" -Level "INFO"
Write-Log "Environment: $Environment" -Level "INFO"
Write-Log "Strict Mode: $StrictMode" -Level "INFO"

if (-not (Initialize-YamlModule)) {
    exit 1
}

$bim = Read-BimModel -Path $BimPath
if (-not $bim) {
    exit 1
}

$yaml = Read-DatasourceConfig -Path $DatasourcesConfigFile -ExpectedEnvironment $Environment
if (-not $yaml) {
    exit 1
}

Test-DatasourceSync -Bim $bim -Yaml $yaml | Out-Null
Test-DatasourceConfigValues -Yaml $yaml | Out-Null

Write-Section "Validation Results"

if ($script:ValidationErrors.Count -gt 0) {
    Write-Log "Datasource validation FAILED with $($script:ValidationErrors.Count) error(s)." -Level "ERROR"

    Write-Host ""
    Write-Host "ERRORS:" -ForegroundColor $Colors.Red
    $script:ValidationErrors | ForEach-Object {
        Write-Host " - $_" -ForegroundColor $Colors.Red
    }

    exit 1
}

if ($script:ValidationWarnings.Count -gt 0 -and $StrictMode) {
    Write-Log "Datasource validation FAILED because StrictMode treats warnings as errors." -Level "ERROR"

    Write-Host ""
    Write-Host "WARNINGS:" -ForegroundColor $Colors.Yellow
    $script:ValidationWarnings | ForEach-Object {
        Write-Host " - $_" -ForegroundColor $Colors.Yellow
    }

    exit 1
}

if ($script:ValidationWarnings.Count -gt 0) {
    Write-Log "Datasource validation PASSED with $($script:ValidationWarnings.Count) warning(s)." -Level "WARNING"

    Write-Host ""
    Write-Host "WARNINGS:" -ForegroundColor $Colors.Yellow
    $script:ValidationWarnings | ForEach-Object {
        Write-Host " - $_" -ForegroundColor $Colors.Yellow
    }
}
else {
    Write-Log "Datasource validation PASSED - no errors or warnings." -Level "SUCCESS"
}

Write-Host ""
Write-Host "Summary:" -ForegroundColor $Colors.Green
Write-Host " - Environment: $Environment" -ForegroundColor $Colors.Green
Write-Host " - BIM Datasources: $($bim.model.dataSources.Count)" -ForegroundColor $Colors.Green
Write-Host " - YAML Datasources: $($yaml.datasources.Count)" -ForegroundColor $Colors.Green
Write-Host " - BIM Modified: No" -ForegroundColor $Colors.Green

exit 0
