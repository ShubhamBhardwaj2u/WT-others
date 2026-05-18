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
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
$script:DeploymentStartTime = Get-Date
$script:Errors = @()
$script:ChangesMade = @()

$Colors = @{
    Red   = [ConsoleColor]::Red
    Green = [ConsoleColor]::Green
    Cyan  = [ConsoleColor]::Cyan
    White = [ConsoleColor]::White
    Yellow = [ConsoleColor]::Yellow
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")

    $color = $Colors.White
    switch ($Level) {
        "ERROR"   { $color = $Colors.Red }
        "SUCCESS" { $color = $Colors.Green }
        "WARNING" { $color = $Colors.Yellow }
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

function Write-Step {
    param([string]$Step, [string]$Description)

    Write-Host ""
    Write-Host "$Step - $Description" -ForegroundColor $Colors.White
}

function Add-Error {
    param([string]$Message)

    $script:Errors += $Message
    Write-Log $Message "ERROR"
}

function Initialize-AnalysisServicesLibraries {
    Write-Section "Loading Analysis Services Libraries"

    $coreDll = "C:\Program Files\Microsoft SQL Server Management Studio 22\Release\Common7\IDE\Microsoft.AnalysisServices.Core.dll"
    $tabularDll = "C:\Program Files\Microsoft SQL Server Management Studio 22\Release\Common7\IDE\Microsoft.AnalysisServices.Tabular.dll"

    if (-not (Test-Path $coreDll)) {
        Add-Error "Core DLL not found: $coreDll"
        return $false
    }

    if (-not (Test-Path $tabularDll)) {
        Add-Error "Tabular DLL not found: $tabularDll"
        return $false
    }

    try {
        Add-Type -Path $coreDll -ErrorAction Stop
        Write-Log "Loaded Core DLL: $coreDll" "SUCCESS"

        Add-Type -Path $tabularDll -ErrorAction Stop
        Write-Log "Loaded Tabular DLL: $tabularDll" "SUCCESS"

        return $true
    }
    catch {
        Add-Error "Failed to load Analysis Services libraries: $($_.Exception.Message)"
        return $false
    }
}

function Get-DatabaseFromBim {
    param([string]$Path)

    Write-Step "2" "Reading BIM File"

    try {
        $json = Get-Content $Path -Raw -Encoding UTF8
        $database = [Microsoft.AnalysisServices.Tabular.JsonSerializer]::DeserializeDatabase($json)

        if ($null -eq $database) {
            throw "BIM deserialization returned null."
        }

        Write-Log "BIM deserialized successfully. Source database name: $($database.Name)" "SUCCESS"
        return $database
    }
    catch {
        Add-Error "Failed to read BIM file: $($_.Exception.Message)"
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

    Write-Log "Target database name set to: $Name" "SUCCESS"
    $script:ChangesMade += "Database identity set to $Name"
}

function Connect-SsasServer {
    param([string]$ServerName)

    Write-Step "4" "Connecting to SSAS Server"

    $server = New-Object Microsoft.AnalysisServices.Tabular.Server

    try {
        Write-Log "Connecting to SSAS server: $ServerName"
        $server.Connect($ServerName)

        if (-not $server.Connected) {
            throw "Connection established but server is not connected."
        }

        Write-Log "Connected to SSAS server: $ServerName" "SUCCESS"
        return $server
    }
    catch {
        Add-Error "Failed to connect to SSAS server: $($_.Exception.Message)"
        throw
    }
}

function Deploy-Database {
    param(
        [object]$Server,
        [object]$Database,
        [string]$Name
    )

    Write-Step "5" "Deploying BIM to SSAS"

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
            Write-Log "[WHATIF] Would deploy database '$Name' to server '$SsasServer'" "WARNING"
            return $null
        }

        $Server.Execute($tmsl)
        $Server.Databases.Refresh()

        $deployedDb = $Server.Databases.FindByName($Name)

        if ($null -eq $deployedDb) {
            throw "Deployment completed but database '$Name' was not found after refresh."
        }

        $deployedDb.Refresh()

        if ($null -eq $deployedDb.Model) {
            throw "Database '$Name' found but model is null after deployment."
        }

        Write-Log "Database deployed successfully: $Name" "SUCCESS"
        $script:ChangesMade += "Created/Replaced database: $Name"

        return $deployedDb
    }
    catch {
        Add-Error "TMSL deployment failed: $($_.Exception.Message)"
        throw
    }
}

Write-Host ""
Write-Host "============================================================"
Write-Host "        SSAS Tabular BIM Deployment"
Write-Host "============================================================"

Write-Log "Environment : $Environment"
Write-Log "SSAS Server : $SsasServer"
Write-Log "Database    : $DatabaseName"
Write-Log "BIM Path    : $BimPath"
Write-Log "WhatIf      : $WhatIf"

$server = $null

try {
    Write-Step "1" "Loading Analysis Services Libraries"
    if (-not (Initialize-AnalysisServicesLibraries)) {
        exit 1
    }

    $database = Get-DatabaseFromBim -Path $BimPath
    Update-DatabaseIdentity -Database $database -Name $DatabaseName

    $server = Connect-SsasServer -ServerName $SsasServer
    $deployedDb = Deploy-Database -Server $server -Database $database -Name $DatabaseName
}
catch {
    Add-Error "Deployment failed: $($_.Exception.Message)"
}
finally {
    if ($server -and $server.Connected) {
        $server.Disconnect()
        Write-Log "Disconnected from SSAS server" "INFO"
    }
}

$duration = (Get-Date) - $script:DeploymentStartTime

Write-Section "Deployment Results"

if ($script:Errors.Count -gt 0) {
    Write-Log "Deployment FAILED with $($script:Errors.Count) error(s)" "ERROR"

    Write-Host ""
    Write-Host "ERRORS:" -ForegroundColor $Colors.Red
    $script:Errors | ForEach-Object {
        Write-Host " - $_" -ForegroundColor $Colors.Red
    }

    exit 1
}

Write-Log "Deployment completed successfully" "SUCCESS"

Write-Host ""
Write-Host "Summary:" -ForegroundColor $Colors.Green
Write-Host "  Environment : $Environment" -ForegroundColor $Colors.Green
Write-Host "  Server      : $SsasServer" -ForegroundColor $Colors.Green
Write-Host "  Database    : $DatabaseName" -ForegroundColor $Colors.Green
Write-Host "  BIM Path    : $BimPath" -ForegroundColor $Colors.Green
Write-Host "  Duration    : $($duration.ToString('mm\:ss'))" -ForegroundColor $Colors.Green

if ($script:ChangesMade.Count -gt 0) {
    Write-Host ""
    Write-Host "Changes Made:" -ForegroundColor $Colors.Cyan
    $script:ChangesMade | ForEach-Object {
        Write-Host " - $_" -ForegroundColor $Colors.Green
    }
}

exit 0
