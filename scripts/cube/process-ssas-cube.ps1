param(
    [Parameter(Mandatory=$true)]
    [string]$SsasServer,

    [Parameter(Mandatory=$true)]
    [string]$DatabaseName,

    [Parameter(Mandatory=$true)]
    [ValidateSet("Full", "Default", "DataOnly", "Calculate", "None")]
    [string]$ProcessType,

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
    }

    Write-Host "[$Level] $Message" -ForegroundColor $color
}

function Write-Section {
    param([string]$Title)

    Write-Host ""
    Write-Host "=============================================================="
    Write-Host " $Title"
    Write-Host "=============================================================="
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

function Initialize-TomAssembly {

    Write-Section "TOM Library Initialization"

    try {
        Add-Type -AssemblyName "Microsoft.AnalysisServices.Core" -ErrorAction Stop
        Add-Type -AssemblyName "Microsoft.AnalysisServices.Tabular" -ErrorAction Stop

        Write-Log "TOM libraries loaded from GAC" "SUCCESS"
        return
    }
    catch {
        Write-Log "TOM libraries not found in GAC. Trying file paths..." "WARNING"
    }

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

        Add-Error "Unable to load TOM libraries. Install SSMS or provide TOM DLL path."
        throw "TOM library initialization failed."
    }

    return $true
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

        throw "SSAS database not found: $DatabaseName"
    }

    $database.Refresh()

    if ($null -eq $database.Model) {

        throw "SSAS database model is null: $DatabaseName"
    }

    Write-Log "Database found: $DatabaseName" "SUCCESS"

    return $database
}

function Invoke-ModelProcessing {

    param(
        [object]$Database,
        [string]$ProcessType
    )

    Write-Section "Model Processing"

    if ($ProcessType -eq "None") {

        Write-Log "Processing skipped because ProcessType = None" "WARNING"
        return
    }

    $refreshType = switch ($ProcessType) {

        "Full" {
            [Microsoft.AnalysisServices.Tabular.RefreshType]::Full
        }

        "Default" {
            [Microsoft.AnalysisServices.Tabular.RefreshType]::Default
        }

        "DataOnly" {
            [Microsoft.AnalysisServices.Tabular.RefreshType]::DataOnly
        }

        "Calculate" {
            [Microsoft.AnalysisServices.Tabular.RefreshType]::Calculate
        }
    }

    if ($DryRun) {

        Write-Log "[DRYRUN] Would process database using '$ProcessType'" "WARNING"
        return
    }

    try {

        Write-Log "Starting model processing using '$ProcessType'" "INFO"

        $Database.Model.RequestRefresh($refreshType)

        $saveResult = $Database.Model.SaveChanges()

        $hasErrors = $false
        $hasWarnings = $false

        foreach ($xmlaResult in $saveResult.XmlaResults) {

            foreach ($msg in $xmlaResult.Messages) {

                if ($msg.GetType().Name -eq "XmlaError") {

                    Write-Log "ERROR: $($msg.Description)" "ERROR"
                    $hasErrors = $true
                }
                else {

                    Write-Log "WARNING: $($msg.Description)" "WARNING"
                    $hasWarnings = $true
                }
            }
        }

        if ($hasErrors) {

            throw "Model processing failed with SSAS errors."
        }

        if ($hasWarnings) {

            Add-Warning "Model processing completed with warnings."
        }
        else {

            Write-Log "Model processing completed successfully" "SUCCESS"
        }

        $script:ChangesMade += "Processed database using '$ProcessType'"
    }
    catch {

        Add-Error "Model processing failed: $($_.Exception.Message)"
        throw
    }
}

Write-Host ""
Write-Host "=============================================================="
Write-Host "              SSAS Model Processing Tool"
Write-Host "=============================================================="

Write-Log "SSAS Server: $SsasServer"
Write-Log "Database Name: $DatabaseName"
Write-Log "Process Type: $ProcessType"
Write-Log "DryRun: $DryRun"

$server = $null

try {

    Initialize-TomAssembly

    $server = Connect-SsasServer -ServerName $SsasServer

    $database = Get-TargetDatabase `
        -Server $server `
        -DatabaseName $DatabaseName

    Invoke-ModelProcessing `
        -Database $database `
        -ProcessType $ProcessType
}
catch {

    Add-Error "Process execution failed: $($_.Exception.Message)"
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

Write-Log "Model processing completed successfully" "SUCCESS"

Write-Host ""

Write-Host "Summary:" -ForegroundColor $Colors.Green
Write-Host " Server       : $SsasServer" -ForegroundColor $Colors.Green
Write-Host " Database     : $DatabaseName" -ForegroundColor $Colors.Green
Write-Host " Process Type : $ProcessType" -ForegroundColor $Colors.Green
Write-Host " Changes      : $($script:ChangesMade.Count)" -ForegroundColor $Colors.Green
Write-Host " DryRun       : $DryRun" -ForegroundColor $Colors.Green
Write-Host ""

exit 0
