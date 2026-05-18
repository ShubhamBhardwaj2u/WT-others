param(
    [Parameter(Mandatory=$true)]
    [string]$SsasServer,

    [Parameter(Mandatory=$true)]
    [string]$DatabaseName,

    [Parameter(Mandatory=$true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$DatasourcesConfigFile,

    [Parameter(Mandatory=$false)]
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$script:Errors = @()
$script:Warnings = @()
$script:ChangesMade = @()

$Colors = @{
    Red    = [ConsoleColor]::Red
    Yellow = [ConsoleColor]::Yellow
    Green  = [ConsoleColor]::Green
    Cyan   = [ConsoleColor]::Cyan
    White  = [ConsoleColor]::White
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = $Colors.White

    switch ($Level) {
        "ERROR"   { $color = $Colors.Red }
        "WARNING" { $color = $Colors.Yellow }
        "SUCCESS" { $color = $Colors.Green }
        "INFO"    { $color = $Colors.Cyan }
    }

    Write-Host "[$Level] $Message" -ForegroundColor $color
}

function Write-Section {
    param([string]$Title)

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "  $Title"
    Write-Host "============================================================"
}

function Add-Error {
    param([string]$Message)
    $script:Errors += $Message
    Write-Log $Message "ERROR"
}

function Add-Warning {
    param([string]$Message)
    $script:Warnings += $Message
    Write-Log $Message "WARNING"
}

function Initialize-YamlModule {
    Write-Section "YAML Module Initialization"

    try {
        if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
            Install-Module -Name powershell-yaml -Scope CurrentUser -Force -ErrorAction Stop
            Write-Log "Installed powershell-yaml module" "SUCCESS"
        }

        Import-Module powershell-yaml -Force -ErrorAction Stop
        Write-Log "Loaded powershell-yaml module" "SUCCESS"
    }
    catch {
        Add-Error "Failed to initialize powershell-yaml module: $($_.Exception.Message)"
        throw
    }
}

function Initialize-TomAssembly {
    Write-Section "TOM Library Initialization"

    # try {
    #     Add-Type -AssemblyName "Microsoft.AnalysisServices.Core" -ErrorAction Stop
    #     Add-Type -AssemblyName "Microsoft.AnalysisServices.Tabular" -ErrorAction Stop
    #     Write-Log "TOM libraries loaded from GAC" "SUCCESS"
    #     return
    # }
    # catch {
    #     Write-Log "TOM libraries not found in GAC. Trying file paths..." "WARNING"
    # }

    $possiblePaths = @(
        "C:\Program Files\Microsoft SQL Server Management Studio 22\Release\Common7\IDE\Microsoft.AnalysisServices.Tabular.dll",
        "C:\Program Files\Microsoft SQL Server Management Studio 22\Release\Common7\IDE\Microsoft.AnalysisServices.Core.dll"
    )

    $anyLoaded = $false
    
    foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
            try {
                Add-Type -Path $path -ErrorAction Stop
                Write-Log "TOM library loaded from: $path" -Level "SUCCESS"
                $anyLoaded = $true
            }
            catch {
                Write-Log "Failed loading TOM from: $path" -Level "WARNING"
            }
        }
    }

    if (-not $anyLoaded) {
        Add-Error "Unable to load TOM libraries. Install SSMS or provide -TomDllPath."
        throw "TOM library initialization failed."
    }

    return $true
}

function Read-DatasourceConfig {
    Write-Section "Datasource Configuration Loading"

    try {
        $config = Get-Content $DatasourcesConfigFile -Raw -Encoding UTF8 | ConvertFrom-Yaml

        if (-not $config) {
            throw "Datasource YAML is empty or invalid."
        }

        if (-not $config.environment) {
            throw "Datasource YAML missing 'environment'."
        }

        if (-not $config.datasources -or $config.datasources.Count -eq 0) {
            throw "Datasource YAML has no datasources defined."
        }

        $names = @($config.datasources | ForEach-Object { $_.name.Trim().ToLower() })
        $duplicates = $names | Group-Object | Where-Object { $_.Count -gt 1 }

        if ($duplicates) {
            throw "Duplicate datasource names found in YAML: $($duplicates.Name -join ', ')"
        }

        foreach ($ds in $config.datasources) {
            if ([string]::IsNullOrWhiteSpace($ds.name)) {
                throw "Datasource entry missing name."
            }

            if ([string]::IsNullOrWhiteSpace($ds.server)) {
                throw "Datasource '$($ds.name)' missing server."
            }

            if ([string]::IsNullOrWhiteSpace($ds.database)) {
                throw "Datasource '$($ds.name)' missing database."
            }
        }

        Write-Log "Datasource config loaded successfully" "SUCCESS"
        Write-Log "Environment: $($config.environment)" "INFO"
        Write-Log "Datasource count: $($config.datasources.Count)" "INFO"

        return $config
    }
    catch {
        Add-Error "Failed to read datasource config: $($_.Exception.Message)"
        throw
    }
}

function Connect-SsasServer {
    param(
        [string]$ServerName
    )

    Write-Section "SSAS Connection"

    $server = New-Object Microsoft.AnalysisServices.Tabular.Server

    try {
        Write-Log "Connecting to SSAS server: $ServerName" -Level "INFO"
        $server.Connect($ServerName)

        if (-not $server.Connected) {
            throw "Connection to SSAS server '$ServerName' failed."
        }

        Write-Log "Connected to SSAS server" -Level "SUCCESS"
        Write-Log "SSAS Server Name: $($server.Name)" -Level "INFO"
        Write-Log "SSAS Server Version: $($server.ServerVersion)" -Level "INFO"
        Write-Log "SSAS Server Edition: $($server.Edition)" -Level "INFO"
        Write-Log "SSAS Server Compatibility Level: $($server.CompatibilityLevel)" -Level "INFO"
        Write-Log "SSAS Server Connected: $($server.Connected)" -Level "INFO"

        return $server
    }
    catch {
        Add-Error "Failed to connect to SSAS server '$ServerName': $($_.Exception.Message)"
        throw
    }
}

function Get-TargetDatabase {
    param(
        [object]$Server,
        [string]$DatabaseName
    )

    Write-Section "Database Lookup"

    $Server.Databases.Refresh()
    $database = $Server.Databases.FindByName($DatabaseName)

    if ($null -eq $database) {
        throw "SSAS database not found: $DatabaseName. Run deploy-cube.ps1 first to create the database before applying datasource changes."
    }

    $database.Refresh()

    if ($null -eq $database.Model) {
        throw "SSAS database found but model is null: $DatabaseName. Deployment may have failed."
    }

    if ($null -eq $database.Model.DataSources -or $database.Model.DataSources.Count -eq 0) {
        throw "SSAS database found but no datasources exist in model: $DatabaseName."
    }

    Write-Log "Database found: $DatabaseName" "SUCCESS"
    Write-Log "Datasources in model: $($database.Model.DataSources.Count)" "INFO"

    return $database
}

function Apply-Datasources {
    param(
        [object]$Database,
        [object]$Config
    )

    Write-Section "Applying Datasource Configuration"

    $modelDataSources = $Database.Model.DataSources

    if ($null -eq $modelDataSources -or $modelDataSources.Count -eq 0) {
        throw "Target SSAS database has no datasources."
    }

    $modelNames = @($modelDataSources | ForEach-Object { $_.Name.Trim() })
    $yamlNames  = @($Config.datasources | ForEach-Object { $_.name.Trim() })

    foreach ($yamlName in $yamlNames) {
        if ($yamlName.ToLower() -notin @($modelNames | ForEach-Object { $_.ToLower() })) {
            throw "Datasource '$yamlName' exists in YAML but not in SSAS model."
        }
    }

    foreach ($modelName in $modelNames) {
        if ($modelName.ToLower() -notin @($yamlNames | ForEach-Object { $_.ToLower() })) {
            throw "Datasource '$modelName' exists in SSAS model but not in YAML."
        }
    }

    foreach ($yamlDs in $Config.datasources) {
        $datasource = $modelDataSources | Where-Object {
            $_.Name.Trim().ToLower() -eq $yamlDs.name.Trim().ToLower()
        } | Select-Object -First 1

        if ($null -eq $datasource) {
            throw "Datasource not found in SSAS model: $($yamlDs.name)"
        }

        Write-Host ""
        Write-Log "Processing datasource: $($datasource.Name)" "INFO"

        if ($datasource.PSObject.Properties.Name -notcontains "ConnectionString") {
            throw "Datasource '$($datasource.Name)' does not expose ConnectionString property."
        }

        $oldConnectionString = $datasource.ConnectionString
        $newConnectionString = Update-ConnectionString `
            -ConnectionString $oldConnectionString `
            -Server $yamlDs.server `
            -Database $yamlDs.database

        $oldImpersonation = $datasource.ImpersonationMode
        $targetImpersonation = [Microsoft.AnalysisServices.Tabular.ImpersonationMode]::ImpersonateServiceAccount

        if ($DryRun) {
            Write-Log "[DRYRUN] Would update datasource '$($datasource.Name)'" "WARNING"
            Write-Host "  Old Connection String: $oldConnectionString"
            Write-Host "  New Connection String: $newConnectionString"
            Write-Host "  Impersonation: $oldImpersonation -> $targetImpersonation"
            continue
        }

        $changed = $false

        if ($oldConnectionString -ne $newConnectionString) {
            $datasource.ConnectionString = $newConnectionString
            $changed = $true
            Write-Log "Connection string updated for datasource '$($datasource.Name)'" "SUCCESS"
        }
        else {
            Write-Log "Connection string already matches target config" "INFO"
        }

        if ($datasource.ImpersonationMode -ne $targetImpersonation) {
            $datasource.ImpersonationMode = $targetImpersonation
            $changed = $true
            Write-Log "Impersonation updated to ImpersonateServiceAccount" "SUCCESS"
        }

        if ($changed) {
            $script:ChangesMade++
        }
    }

    if ($DryRun) {
        Write-Log "DRYRUN completed. No SSAS changes were saved." "WARNING"
        return
    }

    if ($script:ChangesMade -gt 0) {
        Write-Section "Saving SSAS Model Changes"
        $Database.Model.SaveChanges()
        Write-Log "SSAS datasource changes saved successfully" "SUCCESS"
    }
    else {
        Write-Log "No datasource changes required." "INFO"
    }
}

function Update-ConnectionString {
    param(
        [string]$ConnectionString,
        [string]$Server,
        [string]$Database
    )

    if ([string]::IsNullOrWhiteSpace($ConnectionString)) {
        throw "Existing datasource connection string is empty."
    }

    $result = $ConnectionString

    if ($result -match "(?i)(Data Source\s*=\s*)[^;]*") {
        $result = $result -replace "(?i)(Data Source\s*=\s*)[^;]*", "`${1}$Server"
    }
    else {
        throw "Connection string does not contain 'Data Source'."
    }

    if ($result -match "(?i)(Initial Catalog\s*=\s*)[^;]*") {
        $result = $result -replace "(?i)(Initial Catalog\s*=\s*)[^;]*", "`${1}$Database"
    }
    else {
        throw "Connection string does not contain 'Initial Catalog'."
    }

    return $result
}


Write-Host ""
Write-Host "============================================================"
Write-Host "        SSAS Datasource Apply Tool"
Write-Host "============================================================"

Write-Log "SSAS Server: $SsasServer"
Write-Log "Database Name: $DatabaseName"
Write-Log "Config File: $DatasourcesConfigFile"
Write-Log "DryRun: $DryRun"

$server = $null

try {
    Initialize-YamlModule
    Initialize-TomAssembly

    $config = Read-DatasourceConfig
    $server = Connect-SsasServer -ServerName $SsasServer
    $database = Get-TargetDatabase -Server $server -DatabaseName $DatabaseName

    Apply-Datasources -Database $database -Config $config
}
catch {
    Add-Error "Datasource apply failed: $($_.Exception.Message)"
}
finally {
    if ($server -and $server.Connected) {
        $server.Disconnect()
        Write-Log "Disconnected from SSAS server" "INFO"
    }
}

Write-Section "Execution Results"

if ($script:Errors.Count -gt 0) {
    Write-Log "FAILED with $($script:Errors.Count) error(s)" "ERROR"

    Write-Host ""
    Write-Host "ERRORS:" -ForegroundColor $Colors.Red
    $script:Errors | ForEach-Object {
        Write-Host " - $_" -ForegroundColor $Colors.Red
    }

    exit 1
}

if ($script:Warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "WARNINGS:" -ForegroundColor $Colors.Yellow
    $script:Warnings | ForEach-Object {
        Write-Host " - $_" -ForegroundColor $Colors.Yellow
    }
}

Write-Log "Datasource apply completed successfully" "SUCCESS"
Write-Host ""
Write-Host "Summary:" -ForegroundColor $Colors.Green
Write-Host "  Server      : $SsasServer" -ForegroundColor $Colors.Green
Write-Host "  Database    : $DatabaseName" -ForegroundColor $Colors.Green
Write-Host "  Config File : $DatasourcesConfigFile" -ForegroundColor $Colors.Green
Write-Host "  Changes     : $script:ChangesMade" -ForegroundColor $Colors.Green
Write-Host "  DryRun      : $DryRun" -ForegroundColor $Colors.Green

exit 0
