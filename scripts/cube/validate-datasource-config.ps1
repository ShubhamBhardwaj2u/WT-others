param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$DatasourcesConfigFile,

    [Parameter(Mandatory=$true, Position=1)]
    [ValidateSet("DEV", "UAT", "PROD")]
    [string]$Environment
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
    Write-Host "======================================================================"
    Write-Host "  $Title"
    Write-Host "======================================================================"
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
            Write-Log "powershell-yaml module not found. Installing..." -Level "WARNING"
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

function Test-YamlSyntax {
    param([string]$Path)

    Write-Section "Step 2: YAML Syntax Validation"

    try {
        $content = Get-Content $Path -Raw -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace($content)) {
            Add-ValidationError "Datasource YAML file is empty"
            return $false
        }

        $yamlData = $content | ConvertFrom-Yaml -ErrorAction Stop

        if (-not $yamlData) {
            Add-ValidationError "Datasource YAML could not be parsed"
            return $false
        }

        Write-Log "YAML syntax is valid" -Level "SUCCESS"
        return $yamlData
    }
    catch {
        Add-ValidationError "Invalid YAML syntax: $($_.Exception.Message)"
        return $false
    }
}

function Test-Environment {
    param(
        [object]$YamlData,
        [string]$ExpectedEnvironment
    )

    Write-Section "Step 3: Environment Validation"

    if (-not $YamlData.environment) {
        Add-ValidationError "Missing required property: environment"
        return $false
    }

    if ($YamlData.environment -ne $ExpectedEnvironment) {
        Add-ValidationError "Environment mismatch: '$($YamlData.environment)' found, expected '$ExpectedEnvironment'"
        return $false
    }

    Write-Log "Environment validated: $ExpectedEnvironment" -Level "SUCCESS"
    return $true
}

function Test-DatasourceCollection {
    param([object]$YamlData)

    Write-Section "Step 4: Datasource Collection Validation"

    if (-not $YamlData.datasources) {
        Add-ValidationError "Missing required property: datasources"
        return $false
    }

    if ($YamlData.datasources.Count -eq 0) {
        Add-ValidationError "No datasources defined in configuration"
        return $false
    }

    Write-Log "Datasource count: $($YamlData.datasources.Count)" -Level "SUCCESS"
    return $true
}

function Test-DuplicateDatasourceNames {
    param([array]$Datasources)

    Write-Section "Step 5: Duplicate Datasource Validation"

    $datasourceNames = $Datasources | ForEach-Object { $_.name.Trim().ToLower() }
    $duplicates = $datasourceNames | Group-Object | Where-Object Count -gt 1

    if ($duplicates) {
        Add-ValidationError "Duplicate datasource names found: $($duplicates.Name -join ', ')"
        return $false
    }

    Write-Log "No duplicate datasource names found" -Level "SUCCESS"
    return $true
}

function Test-DatasourceProperties {
    param([array]$Datasources)

    Write-Section "Step 6: Datasource Property Validation"

    $isValid = $true

    foreach ($datasource in $Datasources) {
        Write-Log "Validating datasource: $($datasource.name)" -Level "INFO"

        if ([string]::IsNullOrWhiteSpace($datasource.name)) {
            Add-ValidationError "Datasource name is missing"
            $isValid = $false
            continue
        }

        if ([string]::IsNullOrWhiteSpace($datasource.server)) {
            Add-ValidationError "Datasource '$($datasource.name)' is missing server"
            $isValid = $false
        }

        if ([string]::IsNullOrWhiteSpace($datasource.database)) {
            Add-ValidationError "Datasource '$($datasource.name)' is missing database"
            $isValid = $false
        }

        if ($datasource.server -and $datasource.server -notmatch '^[a-zA-Z0-9\.\-_]+$') {
            Add-ValidationWarning "Datasource '$($datasource.name)' server name contains unusual characters: $($datasource.server)"
        }

        Write-Log "Datasource validated: $($datasource.name)" -Level "SUCCESS"
    }

    return $isValid
}

Write-Host ""
Write-Host "======================================================================"
Write-Host "              SSAS Datasource Configuration Validation"
Write-Host "======================================================================"

Write-Log "Starting validation for: $DatasourcesConfigFile"
Write-Log "Expected Environment: $Environment"

$allPassed = $true

if (-not (Initialize-YamlModule)) {
    $allPassed = $false
}

$yamlData = $null

if ($allPassed) {
    $yamlData = Test-YamlSyntax -Path $DatasourcesConfigFile
    if (-not $yamlData) {
        $allPassed = $false
    }
}

if ($allPassed) {
    if (-not (Test-Environment -YamlData $yamlData -ExpectedEnvironment $Environment)) {
        $allPassed = $false
    }

    if (-not (Test-DatasourceCollection -YamlData $yamlData)) {
        $allPassed = $false
    }

    if ($allPassed) {
        if (-not (Test-DuplicateDatasourceNames -Datasources $yamlData.datasources)) {
            $allPassed = $false
        }

        if (-not (Test-DatasourceProperties -Datasources $yamlData.datasources)) {
            $allPassed = $false
        }
    }
}

Write-Section "Validation Results"

if ($script:ValidationErrors.Count -gt 0) {
    Write-Log "Validation FAILED with $($script:ValidationErrors.Count) error(s)" -Level "ERROR"

    Write-Host ""
    Write-Host "ERRORS:" -ForegroundColor $Colors.Red
    $script:ValidationErrors | ForEach-Object {
        Write-Host " - $_" -ForegroundColor $Colors.Red
    }

    exit 1
}

if ($script:ValidationWarnings.Count -gt 0) {
    Write-Log "Validation PASSED with $($script:ValidationWarnings.Count) warning(s)" -Level "WARNING"

    Write-Host ""
    Write-Host "WARNINGS:" -ForegroundColor $Colors.Yellow
    $script:ValidationWarnings | ForEach-Object {
        Write-Host " - $_" -ForegroundColor $Colors.Yellow
    }
}
else {
    Write-Log "Validation PASSED - no errors or warnings" -Level "SUCCESS"
}

Write-Host ""
Write-Host "Summary:" -ForegroundColor $Colors.Green
Write-Host "  Config File : $DatasourcesConfigFile" -ForegroundColor $Colors.Green
Write-Host "  Environment : $Environment" -ForegroundColor $Colors.Green
Write-Host "  Datasources : $($yamlData.datasources.Count)" -ForegroundColor $Colors.Green

exit 0
