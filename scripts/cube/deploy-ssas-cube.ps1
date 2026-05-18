param(
    [Parameter(Mandatory=$true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$BimPath,

    [Parameter(Mandatory=$true)]
    [ValidateSet("DEV", "UAT", "PROD")]
    [string]$Environment,

    [Parameter(Mandatory=$true)]
    [string]$SsasServer,

    [Parameter(Mandatory=$true)]
    [string]$DatabaseName,

    [Parameter(Mandatory=$false)]
    [ValidateSet("true", "false")]
    [string]$CreateDatabaseIfNotExists = "true",

    [Parameter(Mandatory=$false)]
    [switch]$VerboseLogging,

    [Parameter(Mandatory=$false)]
    [switch]$WhatIf
)

$CreateDatabaseIfNotExistsBool = [System.Convert]::ToBoolean($CreateDatabaseIfNotExists)

$ErrorActionPreference = "Stop"
$script:DeploymentStartTime = Get-Date
$script:Errors = @()
$script:Warnings = @()
$script:ChangesMade = @()

if ($VerboseLogging) {
    $VerbosePreference = "Continue"
}

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
    Write-Host "  $Title"
    Write-Host "============================================================"
}

function Write-Step {
    param(
        [string]$Step,
        [string]$Description
    )

    Write-Host ""
    Write-Host "$Step - $Description" -ForegroundColor $Colors.White
}

function Add-Error {
    param([string]$Message)

    $script:Errors += $Message
    Write-Log $Message -Level "ERROR"
}

function Add-Warning {
    param([string]$Message)

    $script:Warnings += $Message
    Write-Log $Message -Level "WARNING"
}

function Initialize-AnalysisServicesLibraries {
    Write-Section "Analysis Services Library Initialization"

    $coreDll = "C:\Program Files\Microsoft SQL Server Management Studio 22\Release\Common7\IDE\Microsoft.AnalysisServices.Core.dll"
    $tabularDll = "C:\Program Files\Microsoft SQL Server Management Studio 22\Release\Common7\IDE\Microsoft.AnalysisServices.Tabular.dll"

    if (-not (Test-Path $coreDll)) {
        Add-Error "Analysis Services Core library not found: $coreDll"
        return $false
    }

    if (-not (Test-Path $tabularDll)) {
        Add-Error "Analysis Services Tabular library not found: $tabularDll"
        return $false
    }

    try {
        Add-Type -Path $coreDll -ErrorAction Stop
        Write-Log "Analysis Services Core library loaded from: $coreDll" -Level "SUCCESS"

        Add-Type -Path $tabularDll -ErrorAction Stop
        Write-Log "Analysis Services Tabular library loaded from: $tabularDll" -Level "SUCCESS"

        return $true
    }
    catch {
        Add-Error "Failed to load Analysis Services libraries: $($_.Exception.Message)"
        return $false
    }
}

function Get-DatabaseFromBim {
    param([string]$Path)

    Write-Step "2" "Deserializing BIM Model"

    try {
        $json = Get-Content $Path -Raw -Encoding UTF8
        $database = [Microsoft.AnalysisServices.Tabular.JsonSerializer]::DeserializeDatabase($json)

        if ($null -eq $database) {
            throw "BIM deserialization returned null."
        }

        if ($null -eq $database.Model) {
            throw "BIM file does not contain a valid model object."
        }

        Write-Log "BIM model deserialized successfully: $($database.Name)" -Level "SUCCESS"
        return $database
    }
    catch {
        Add-Error "Failed to deserialize BIM file: $($_.Exception.Message)"
        throw
    }
}

function Update-DatabaseIdentity {
    param(
        [object]$Database,
        [string]$Name
    )

    Write-Step "3" "Setting Target Database Identity"

    $Database.Name = $Name
    $Database.ID = $Name

    Write-Log "Database identity set to: $Name" -Level "SUCCESS"
    $script:ChangesMade += "Database identity updated to: $Name"
}

function Connect-SsasServer {
    param([string]$ServerName)

    Write-Step "4" "Connecting to SSAS Server"

    $server = New-Object Microsoft.AnalysisServices.Tabular.Server

    try {
        Write-Log "Connecting to SSAS server: $ServerName" -Level "INFO"
        $server.Connect($ServerName)

        if (-not $server.Connected) {
            throw "Connection established but server is not in connected state."
        }

        Write-Log "Connected to SSAS server: $ServerName" -Level "SUCCESS"
        Write-Log "Server Version: $($server.Version)" -Level "INFO"
        Write-Log "Server Edition: $($server.Edition)" -Level "INFO"

        return $server
    }
    catch {
        Add-Error "Failed to connect to SSAS server: $($_.Exception.Message)"
        throw
    }
}

function Test-DatabaseDeploymentAllowed {
    param(
        [object]$Server,
        [string]$Name
    )

    Write-Step "5" "Validating Target Database"

    $Server.Databases.Refresh()
    $existingDatabase = $Server.Databases.FindByName($Name)

    if ($null -eq $existingDatabase) {
        if (-not $CreateDatabaseIfNotExistsBool) {
            throw "Database '$Name' does not exist and CreateDatabaseIfNotExists is set to false."
        }

        Write-Log "Database '$Name' does not exist. It will be created." -Level "WARNING"
        return
    }

    Write-Log "Database '$Name' already exists. It will be replaced." -Level "WARNING"
}

function Invoke-DatabaseDeployment {
    param(
        [object]$Server,
        [object]$Database,
        [string]$Name
    )

    Write-Step "6" "Deploying BIM Database"

    try {
        $databaseJson = [Microsoft.AnalysisServices.Tabular.JsonSerializer]::SerializeDatabase($Database)
        $databaseObj = $databaseJson | ConvertFrom-Json

        $databaseObj.name = $Name
        $databaseObj.id = $Name

        $tmsl = @{
            createOrReplace = @{
                object = @{
                    database = $Name
                }
                database = $databaseObj
            }
        } | ConvertTo-Json -Depth 100

        if ($WhatIf) {
            Write-Log "[WHATIF] Would execute TMSL createOrReplace for database: $Name" -Level "WARNING"
            return $null
        }

        $Server.Execute($tmsl)
        $Server.Databases.Refresh()

        $deployedDatabase = $Server.Databases.FindByName($Name)

        if ($null -eq $deployedDatabase) {
            throw "Deployment completed but database '$Name' could not be found after refresh."
        }

        $deployedDatabase.Refresh()

        if ($null -eq $deployedDatabase.Model) {
            throw "Database '$Name' found but model is null after deployment."
        }

        Write-Log "Database deployed successfully: $Name" -Level "SUCCESS"
        $script:ChangesMade += "Created/Replaced database: $Name"

        return $deployedDatabase
    }
    catch {
        Add-Error "TMSL deployment failed: $($_.Exception.Message)"
        throw
    }
}

Write-Host ""
Write-Host "============================================================"
Write-Host "              SSAS Tabular BIM Deployment"
Write-Host "============================================================"

Write-Log "Deployment started at: $script:DeploymentStartTime" -Level "INFO"

if ($WhatIf) {
    Write-Log "WHATIF MODE: No actual deployment changes will be made" -Level "WARNING"
}

Write-Step "1" "Deployment Configuration"
Write-Host "- BIM Path                 : $BimPath" -ForegroundColor $Colors.White
Write-Host "- Environment              : $Environment" -ForegroundColor $Colors.White
Write-Host "- SSAS Server              : $SsasServer" -ForegroundColor $Colors.White
Write-Host "- Database                 : $DatabaseName" -ForegroundColor $Colors.White
Write-Host "- Create If Not Exists     : $CreateDatabaseIfNotExists" -ForegroundColor $Colors.White
Write-Host "- WhatIf                   : $WhatIf" -ForegroundColor $Colors.White

$server = $null

try {
    if (-not (Initialize-AnalysisServicesLibraries)) {
        exit 1
    }

    $database = Get-DatabaseFromBim -Path $BimPath

    Update-DatabaseIdentity -Database $database -Name $DatabaseName

    $server = Connect-SsasServer -ServerName $SsasServer

    Test-DatabaseDeploymentAllowed -Server $server -Name $DatabaseName

    $deployedDatabase = Invoke-DatabaseDeployment `
        -Server $server `
        -Database $database `
        -Name $DatabaseName
}
catch {
    Add-Error "Deployment failed: $($_.Exception.Message)"
}
finally {
    if ($server -and $server.Connected) {
        $server.Disconnect()
        Write-Log "Disconnected from SSAS server" -Level "INFO"
    }
}

$script:DeploymentEndTime = Get-Date
$duration = $script:DeploymentEndTime - $script:DeploymentStartTime

Write-Section "Deployment Results"

if ($script:Errors.Count -gt 0) {
    Write-Log "Deployment FAILED with $($script:Errors.Count) error(s)" -Level "ERROR"

    Write-Host ""
    Write-Host "ERRORS:" -ForegroundColor $Colors.Red
    $script:Errors | ForEach-Object {
        Write-Host " - $_" -ForegroundColor $Colors.Red
    }

    exit 1
}

Write-Log "Deployment completed successfully" -Level "SUCCESS"

Write-Host ""
Write-Host "Summary:" -ForegroundColor $Colors.Green
Write-Host "  Environment          : $Environment" -ForegroundColor $Colors.Green
Write-Host "  Server               : $SsasServer" -ForegroundColor $Colors.Green
Write-Host "  Database             : $DatabaseName" -ForegroundColor $Colors.Green
Write-Host "  BIM Path             : $BimPath" -ForegroundColor $Colors.Green
Write-Host "  Create If Not Exists : $CreateDatabaseIfNotExists" -ForegroundColor $Colors.Green
Write-Host "  Duration             : $($duration.ToString('mm\:ss'))" -ForegroundColor $Colors.Green

if ($script:ChangesMade.Count -gt 0) {
    Write-Host ""
    Write-Host "Changes Made:" -ForegroundColor $Colors.Cyan
    $script:ChangesMade | ForEach-Object {
        Write-Host " - $_" -ForegroundColor $Colors.Green
    }
}

if ($script:Warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "Warnings:" -ForegroundColor $Colors.Yellow
    $script:Warnings | ForEach-Object {
        Write-Host " - $_" -ForegroundColor $Colors.Yellow
    }
}

exit 0
