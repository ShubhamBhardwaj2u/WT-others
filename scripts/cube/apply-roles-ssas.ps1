param(
    [Parameter(Mandatory=$true)]
    [string]$SsasServer,

    [Parameter(Mandatory=$true)]
    [string]$DatabaseName,

    [Parameter(Mandatory=$true)]
    [ValidateSet("DEV", "UAT", "PROD")]
    [string]$Environment,

    [Parameter(Mandatory=$true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$RolesConfigFile,

    [Parameter(Mandatory=$false)]
    [switch]$ValidateAD,

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
        "C:\Program Files\Microsoft SQL Server Management Studio 22\Release\Common7\IDE\Microsoft.AnalysisServices.Core.dll",
        "C:\Program Files\Microsoft SQL Server Management Studio 22\Release\Common7\IDE\Microsoft.AnalysisServices.Tabular.dll"
    )

    foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
            try {
                Add-Type -Path $path -ErrorAction Stop
                Write-Log "TOM library loaded from: $path" -Level "SUCCESS"
            }
            catch {
                Write-Log "Failed loading TOM from: $path" -Level "WARNING"
            }
        }
    }
}

function Read-RolesConfig {
    Write-Section "Roles Configuration Loading"

    try {
        $config = Get-Content $RolesConfigFile -Raw -Encoding UTF8 | ConvertFrom-Yaml

        if (-not $config) {
            throw "Roles YAML is empty or invalid."
        }

        if ($config.environment -ne $Environment) {
            throw "Environment mismatch. YAML has '$($config.environment)', expected '$Environment'."
        }

        if (-not $config.roles -or $config.roles.Count -eq 0) {
            throw "Roles YAML has no roles defined."
        }

        $roleNames = @($config.roles | ForEach-Object { $_.name.Trim().ToLower() })
        $duplicates = $roleNames | Group-Object | Where-Object { $_.Count -gt 1 }

        if ($duplicates) {
            throw "Duplicate role names found in YAML: $($duplicates.Name -join ', ')"
        }

        foreach ($role in $config.roles) {
            if ([string]::IsNullOrWhiteSpace($role.name)) {
                throw "Role entry missing name."
            }

            if (-not $role.members -or $role.members.Count -eq 0) {
                throw "Role '$($role.name)' has no members."
            }

            foreach ($member in $role.members) {
                if ($member -notmatch "^[^\\]+\\[^\\]+$") {
                    throw "Invalid member '$member' in role '$($role.name)'. Expected format DOMAIN\GroupName."
                }
            }
        }

        Write-Log "Roles config loaded successfully" "SUCCESS"
        Write-Log "Environment: $($config.environment)" "INFO"
        Write-Log "Role count: $($config.roles.Count)" "INFO"

        return $config
    }
    catch {
        Add-Error "Failed to read roles config: $($_.Exception.Message)"
        throw
    }
}

function Test-ADGroups {
    param([object]$Config)

    if (-not $ValidateAD) {
        Write-Log "AD validation skipped" "WARNING"
        return
    }

    Write-Section "Active Directory Validation"

    try {
        Import-Module ActiveDirectory -ErrorAction Stop
    }
    catch {
        Add-Error "ActiveDirectory module not available. Install RSAT tools or run without -ValidateAD."
        throw
    }

    foreach ($role in $Config.roles) {
        foreach ($member in $role.members) {
            $groupName = ($member -split "\\", 2)[1]

            try {
                Get-ADGroup -Identity $groupName -ErrorAction Stop | Out-Null
                Write-Log "Validated AD group: $member" "SUCCESS"
            }
            catch {
                Add-Error "AD group not found: $member"
            }
        }
    }

    if ($script:Errors.Count -gt 0) {
        throw "AD validation failed."
    }
}

function Connect-SsasServer {
    param([string]$ServerName)

    Write-Section "SSAS Connection"

    $server = New-Object Microsoft.AnalysisServices.Tabular.Server

    try {
        Write-Log "Connecting to SSAS server: $ServerName" "INFO"
        $server.Connect($ServerName)

        if (-not $server.Connected) {
            throw "Connection to SSAS server failed."
        }

        Write-Log "Connected to SSAS server" "SUCCESS"
        Write-Log "SSAS Server Version: $($server.Version)" "INFO"

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
        throw "SSAS database not found: $DatabaseName. Run deploy-cube.ps1 first."
    }

    $database.Refresh()

    if ($null -eq $database.Model) {
        throw "SSAS database found but model is null: $DatabaseName"
    }

    if ($null -eq $database.Model.Roles -or $database.Model.Roles.Count -eq 0) {
        throw "SSAS database has no roles. Roles must exist in BIM and be deployed first."
    }

    Write-Log "Database found: $DatabaseName" "SUCCESS"
    Write-Log "Roles in model: $($database.Model.Roles.Count)" "INFO"

    return $database
}

function Apply-Roles {
    param(
        [object]$Database,
        [object]$Config
    )

    Write-Section "Applying Role Members"

    $modelRoles = $Database.Model.Roles

    $yamlRoleNames = @($Config.roles | ForEach-Object { $_.name.Trim() })
    $ssasRoleNames = @($modelRoles | ForEach-Object { $_.Name.Trim() })

    foreach ($yamlRoleName in $yamlRoleNames) {
        if ($yamlRoleName.ToLower() -notin @($ssasRoleNames | ForEach-Object { $_.ToLower() })) {
            throw "Role '$yamlRoleName' exists in YAML but not in SSAS model. Add the role in BIM first and redeploy cube."
        }
    }

    foreach ($ssasRoleName in $ssasRoleNames) {
        if ($ssasRoleName.ToLower() -notin @($yamlRoleNames | ForEach-Object { $_.ToLower() })) {
            throw "Role '$ssasRoleName' exists in SSAS model but not in YAML. Add it to roles config or remove it from BIM."
        }
    }

    foreach ($yamlRole in $Config.roles) {
        $role = $modelRoles | Where-Object {
            $_.Name.Trim().ToLower() -eq $yamlRole.name.Trim().ToLower()
        } | Select-Object -First 1

        if ($null -eq $role) {
            throw "Role not found in SSAS model: $($yamlRole.name)"
        }

        Write-Host ""
        Write-Log "Processing role: $($role.Name)" "INFO"

        $existingMembers = @()
        foreach ($member in $role.Members) {
            $existingMembers += $member.MemberName
        }

        $targetMembers = @($yamlRole.members | ForEach-Object { $_.Trim() })

        Write-Log "Existing members: $($existingMembers.Count)" "INFO"
        Write-Log "Target members: $($targetMembers.Count)" "INFO"

        if ($DryRun) {
            Write-Log "[DRYRUN] Would replace members for role '$($role.Name)'" "WARNING"
            foreach ($member in $targetMembers) {
                Write-Host "  + $member" -ForegroundColor $Colors.Green
            }
            continue
        }

        $role.Members.Clear()

        foreach ($memberName in $targetMembers) {
            $roleMember = New-Object Microsoft.AnalysisServices.Tabular.WindowsModelRoleMember
            $roleMember.MemberName = $memberName
            $role.Members.Add($roleMember)
        }

        $script:ChangesMade += "Updated members for role '$($role.Name)'"
        Write-Log "Role members updated: $($role.Name)" "SUCCESS"
    }

    if ($DryRun) {
        Write-Log "DRYRUN completed. No SSAS changes were saved." "WARNING"
        return
    }

    Write-Section "Saving SSAS Model Changes"

    $Database.Model.SaveChanges()
    Write-Log "Role changes saved successfully" "SUCCESS"
}

Write-Host ""
Write-Host "============================================================"
Write-Host "             SSAS Role Apply Tool"
Write-Host "============================================================"

Write-Log "SSAS Server : $SsasServer"
Write-Log "Database    : $DatabaseName"
Write-Log "Environment : $Environment"
Write-Log "Config File : $RolesConfigFile"
Write-Log "DryRun      : $DryRun"
Write-Log "ValidateAD  : $ValidateAD"

$server = $null

try {
    Initialize-YamlModule
    Initialize-TomAssembly

    $config = Read-RolesConfig
    Test-ADGroups -Config $config

    $server = Connect-SsasServer -ServerName $SsasServer
    $database = Get-TargetDatabase -Server $server -DatabaseName $DatabaseName

    Apply-Roles -Database $database -Config $config
}
catch {
    Add-Error "Role apply failed: $($_.Exception.Message)"
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

Write-Log "Role apply completed successfully" "SUCCESS"

Write-Host ""
Write-Host "Summary:" -ForegroundColor $Colors.Green
Write-Host "  Server      : $SsasServer" -ForegroundColor $Colors.Green
Write-Host "  Database    : $DatabaseName" -ForegroundColor $Colors.Green
Write-Host "  Environment : $Environment" -ForegroundColor $Colors.Green
Write-Host "  Config File : $RolesConfigFile" -ForegroundColor $Colors.Green
Write-Host "  Changes     : $($script:ChangesMade.Count)" -ForegroundColor $Colors.Green
Write-Host "  DryRun      : $DryRun" -ForegroundColor $Colors.Green
Write-Host ""

exit 0
