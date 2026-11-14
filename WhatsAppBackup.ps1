[CmdletBinding()]
param(
    [ValidateSet('menu','status','organize','backup','list','verify','restore-prep','cleanup')]
    [string]$Action = 'menu',

    [string]$RecoveryPoint,

    [switch]$DeepVerify
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.0.0'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptRoot 'config.json'

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=' * 72)
    Write-Host $Title
    Write-Host ('=' * 72)
}

function Write-Ok    { param([string]$Text) Write-Host "[OK]   $Text" -ForegroundColor Green }
function Write-Warn  { param([string]$Text) Write-Host "[WARN] $Text" -ForegroundColor Yellow }
function Write-Info  { param([string]$Text) Write-Host "[INFO] $Text" -ForegroundColor Cyan }
function Write-Fail  { param([string]$Text) Write-Host "[FAIL] $Text" -ForegroundColor Red }

function Format-Bytes {
    param([Int64]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Format-Age {
    param([TimeSpan]$Age)
    if ($Age.TotalSeconds -lt 0) { return '0m' }
    if ($Age.TotalDays -ge 1) { return ('{0}d {1}h {2}m' -f [int]$Age.TotalDays, $Age.Hours, $Age.Minutes) }
    if ($Age.TotalHours -ge 1) { return ('{0}h {1}m' -f [int]$Age.TotalHours, $Age.Minutes) }
    return ('{0}m' -f [int]$Age.TotalMinutes)
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Resolve-ConfiguredPath {
    param([string]$Value)
    if ([System.IO.Path]::IsPathRooted($Value)) { return [System.IO.Path]::GetFullPath($Value) }
    return [System.IO.Path]::GetFullPath((Join-Path $ScriptRoot $Value))
}

function Load-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Missing config file: $ConfigPath"
    }
    $raw = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

    $cfg = [ordered]@{}
    $cfg.RootPath = Resolve-ConfiguredPath $raw.RootPath
    $cfg.RecoveryPointsPath = Join-Path $cfg.RootPath $raw.RecoveryPointsDirectory
    $cfg.SharedMediaPath = Join-Path $cfg.RootPath $raw.SharedMediaDirectory
    $cfg.LogsPath = Join-Path $cfg.RootPath $raw.LogsDirectory
    $cfg.ToolsPath = Join-Path $cfg.RootPath $raw.ToolsDirectory
    $cfg.RemoteWhatsAppPath = [string]$raw.RemoteWhatsAppPath
    $cfg.MaxBackupAgeHours = [double]$raw.MaxBackupAgeHours
    $cfg.SelectivePullMaxFiles = [int]$raw.SelectivePullMaxFiles
    $cfg.KeepFallbackDatabaseChain = [bool]$raw.KeepFallbackDatabaseChain
    $cfg.ProtectedRecoveryPointIds = @($raw.ProtectedRecoveryPointIds)
    return [pscustomobject]$cfg
}

$Config = Load-Config

function Get-AdbPath {
    $localAdb = Join-Path $Config.ToolsPath 'platform-tools\adb.exe'
    if (Test-Path -LiteralPath $localAdb) { return $localAdb }

    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    throw "adb.exe was not found. Expected '$localAdb' or adb in PATH."
}

$script:AdbPath = Get-AdbPath

function Invoke-AdbText {
    param(
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = & $script:AdbPath @Arguments 2>&1
    $code = $LASTEXITCODE
    if (($code -ne 0) -and (-not $AllowFailure)) {
        $joined = ($output | Out-String).Trim()
        throw "adb failed (exit $code): adb $($Arguments -join ' ')`n$joined"
    }
    return @($output | ForEach-Object { [string]$_ })
}

function Invoke-AdbInteractive {
    param([Parameter(Mandatory=$true)][string[]]$Arguments)
    & $script:AdbPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "adb failed (exit $LASTEXITCODE): adb $($Arguments -join ' ')"
    }
}

function Assert-SingleDevice {
    $lines = Invoke-AdbText -Arguments @('devices')
    $devices = @()
    foreach ($line in $lines) {
        if ($line -match '^([^\s]+)\s+(device|offline|unauthorized)$') {
            $devices += [pscustomobject]@{ Serial=$Matches[1]; State=$Matches[2] }
        }
    }

    $ready = @($devices | Where-Object { $_.State -eq 'device' })
    if ($devices.Count -eq 0) { throw 'No Android device detected by adb.' }
    if ($ready.Count -eq 0) {
        $states = ($devices | ForEach-Object { "$($_.Serial):$($_.State)" }) -join ', '
        throw "No authorized/online adb device. Detected: $states"
    }
    if ($ready.Count -gt 1) {
        $serials = ($ready | ForEach-Object { $_.Serial }) -join ', '
        throw "More than one adb device is connected ($serials). Disconnect all but the intended phone."
    }
    return $ready[0].Serial
}

function Get-DeviceInfo {
    $serial = Assert-SingleDevice
    $model = ((Invoke-AdbText @('shell','getprop ro.product.model')) -join '').Trim()
    $manufacturer = ((Invoke-AdbText @('shell','getprop ro.product.manufacturer')) -join '').Trim()
    $android = ((Invoke-AdbText @('shell','getprop ro.build.version.release')) -join '').Trim()
    $sdk = ((Invoke-AdbText @('shell','getprop ro.build.version.sdk')) -join '').Trim()

    $versionName = $null
    $pkg = Invoke-AdbText -Arguments @('shell','dumpsys package com.whatsapp') -AllowFailure
    foreach ($line in $pkg) {
        if ($line -match 'versionName=([^\s]+)') { $versionName = $Matches[1]; break }
    }

    return [pscustomobject]@{
        Serial = $serial
        Manufacturer = $manufacturer
        Model = $model
        AndroidVersion = $android
        Sdk = $sdk
        WhatsAppVersion = $versionName
    }
}

function Get-RemoteFileInfo {
    param([Parameter(Mandatory=$true)][string]$RemotePath)
    $cmd = "stat -c '%s|%Y' '$RemotePath'"
    $lines = Invoke-AdbText -Arguments @('shell', $cmd) -AllowFailure

    $line = (($lines | Select-Object -First 1) -as [string])
    if (-not $line -or $line -notmatch '^(\d+)\|(\d+)$') { return $null }

    $size = [Int64]$Matches[1]
    $epoch = [Int64]$Matches[2]
    $ts = [DateTimeOffset]::FromUnixTimeSeconds($epoch).ToLocalTime()
    return [pscustomobject]@{
        Path = $RemotePath
        Size = $size
        Epoch = $epoch
        Timestamp = $ts
        Age = ([DateTimeOffset]::Now - $ts)
    }
}

function Get-RemoteDatabaseInfo {
    $path = "$($Config.RemoteWhatsAppPath)/Databases/msgstore.db.crypt14"
    return Get-RemoteFileInfo $path
}

function Get-RemoteSha256 {
    param([Parameter(Mandatory=$true)][string]$RemotePath)
    $cmd = "sha256sum '$RemotePath'"
    $lines = Invoke-AdbText -Arguments @('shell',$cmd) -AllowFailure
    foreach ($line in $lines) {
        if ([string]$line -match '^([0-9a-fA-F]{64})\s+') { return $Matches[1].ToUpperInvariant() }
    }
    return $null
}

function Show-DeviceAndBackupStatus {
    Write-Section 'PHONE STATUS'
    $device = Get-DeviceInfo
    Write-Host "Device:       $($device.Manufacturer) $($device.Model)"
    Write-Host "Serial:       $($device.Serial)"
    Write-Host "Android:      $($device.AndroidVersion) (SDK $($device.Sdk))"
    if ($device.WhatsAppVersion) { Write-Host "WhatsApp:     $($device.WhatsAppVersion)" }

    $db = Get-RemoteDatabaseInfo
    if (-not $db) {
        Write-Fail 'msgstore.db.crypt14 was not found on the phone.'
    } else {
        Write-Host "Database:     msgstore.db.crypt14"
        Write-Host "Size:         $(Format-Bytes $db.Size)"
        Write-Host "Timestamp:    $($db.Timestamp.ToString('yyyy-MM-dd HH:mm:ss zzz'))"
        Write-Host "Age:          $(Format-Age $db.Age)"
        if ($db.Age.TotalHours -le $Config.MaxBackupAgeHours) {
            Write-Ok "Database is within the $($Config.MaxBackupAgeHours)-hour freshness limit."
        } else {
            Write-Warn "Database is older than the $($Config.MaxBackupAgeHours)-hour freshness limit."
        }
    }
}

function Get-RecoveryPointDirectories {
    Ensure-Directory $Config.RecoveryPointsPath
    return @(Get-ChildItem -LiteralPath $Config.RecoveryPointsPath -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
}

function Read-RecoveryMetadata {
    param([string]$PointPath)
    $metaPath = Join-Path $PointPath 'recovery.json'
    if (-not (Test-Path -LiteralPath $metaPath)) { return $null }
    try { return (Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json) } catch { return $null }
}

function Get-RecoveryPointSummary {
    param([System.IO.DirectoryInfo]$Directory)
    $meta = Read-RecoveryMetadata $Directory.FullName
    $dbPath = Join-Path $Directory.FullName 'Databases\msgstore.db.crypt14'
    $db = Get-Item -LiteralPath $dbPath -ErrorAction SilentlyContinue

    $protected = $false
    if ($meta -and $meta.Protected -ne $null) { $protected = [bool]$meta.Protected }
    elseif ($Config.ProtectedRecoveryPointIds -contains $Directory.Name) { $protected = $true }

    return [pscustomobject]@{
        Id = $Directory.Name
        Path = $Directory.FullName
        DatabaseTime = if ($meta -and $meta.DatabaseTimestamp) { [string]$meta.DatabaseTimestamp } elseif ($db) { $db.LastWriteTime.ToString('o') } else { $null }
        DatabaseSize = if ($db) { [Int64]$db.Length } else { 0 }
        Verified = if ($meta -and $meta.Verified -ne $null) { [bool]$meta.Verified } else { $false }
        Protected = $protected
        HasManifest = (Test-Path -LiteralPath (Join-Path $Directory.FullName 'media-manifest.tsv'))
    }
}

function Show-RecoveryPoints {
    Write-Section 'RECOVERY POINTS'
    $dirs = Get-RecoveryPointDirectories
    if ($dirs.Count -eq 0) {
        Write-Host 'No unified recovery points yet.'
        Write-Host "Run: .\WhatsAppBackup.ps1 organize"
        return
    }

    $rows = foreach ($dir in $dirs) {
        $s = Get-RecoveryPointSummary $dir
        [pscustomobject]@{
            Id = $s.Id
            Database = if ($s.DatabaseTime) { ([DateTimeOffset]::Parse($s.DatabaseTime)).ToString('yyyy-MM-dd HH:mm') } else { '?' }
            Size = if ($s.DatabaseSize) { Format-Bytes $s.DatabaseSize } else { '?' }
            Verified = $s.Verified
            Protected = $s.Protected
            MediaManifest = $s.HasManifest
        }
    }
    $rows | Format-Table -AutoSize
}

function Get-PointIdFromDatabase {
    param([string]$PointPath)
    $dbPath = Join-Path $PointPath 'Databases\msgstore.db.crypt14'
    if (-not (Test-Path -LiteralPath $dbPath)) { return $null }
    $db = Get-Item -LiteralPath $dbPath
    return $db.LastWriteTime.ToString('yyyy-MM-dd_HHmm')
}

function Ensure-MediaJunction {
    param([string]$PointPath)
    Ensure-Directory (Split-Path -Parent $Config.SharedMediaPath)
    Ensure-Directory $Config.SharedMediaPath

    $link = Join-Path $PointPath 'Media'
    if (Test-Path -LiteralPath $link) {
        $item = Get-Item -LiteralPath $link -Force
        if ($item.LinkType -eq 'Junction') { return }
        Write-Warn "Not replacing existing non-junction Media path: $link"
        return
    }

    New-Item -ItemType Junction -Path $link -Target $Config.SharedMediaPath | Out-Null
}

function Write-RecoveryMetadata {
    param(
        [string]$PointPath,
        [string]$PointId,
        [bool]$Protected,
        [bool]$Verified,
        $DatabaseTimestamp,
        [string]$DatabaseSha256,
        [Int64]$DatabaseSize,
        $DeviceInfo,
        [Nullable[Int64]]$MediaFileCount,
        [Nullable[Int64]]$MediaBytes,
        [bool]$MediaManifestCaptured
    )

    $existing = Read-RecoveryMetadata $PointPath
    $createdAt = if ($existing -and $existing.CreatedAt) { [string]$existing.CreatedAt } else { [DateTimeOffset]::Now.ToString('o') }

    $meta = [ordered]@{
        SchemaVersion = 1
        ScriptVersion = $ScriptVersion
        RecoveryPointId = $PointId
        CreatedAt = $createdAt
        DatabaseTimestamp = if ($DatabaseTimestamp) { ([DateTimeOffset]$DatabaseTimestamp).ToString('o') } else { $null }
        DatabaseFile = 'Databases/msgstore.db.crypt14'
        DatabaseSize = $DatabaseSize
        DatabaseSha256 = $DatabaseSha256
        Protected = $Protected
        Verified = $Verified
        MediaManifestCaptured = $MediaManifestCaptured
        MediaManifest = if ($MediaManifestCaptured) { 'media-manifest.tsv' } else { $null }
        MediaFileCount = $MediaFileCount
        MediaBytes = $MediaBytes
        Device = if ($DeviceInfo) {
            [ordered]@{
                Serial = $DeviceInfo.Serial
                Manufacturer = $DeviceInfo.Manufacturer
                Model = $DeviceInfo.Model
                AndroidVersion = $DeviceInfo.AndroidVersion
                Sdk = $DeviceInfo.Sdk
                WhatsAppVersion = $DeviceInfo.WhatsAppVersion
            }
        } else { $null }
    }

    $meta | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $PointPath 'recovery.json') -Encoding UTF8
}

function Initialize-MetadataForExistingPoint {
    param([string]$PointPath,[bool]$Protected)
    $dbPath = Join-Path $PointPath 'Databases\msgstore.db.crypt14'
    if (-not (Test-Path -LiteralPath $dbPath)) {
        Write-Warn "No msgstore.db.crypt14 in $PointPath; metadata not created."
        return
    }
    $db = Get-Item -LiteralPath $dbPath
    $hash = (Get-FileHash -LiteralPath $dbPath -Algorithm SHA256).Hash
    $id = Split-Path -Leaf $PointPath
    Write-RecoveryMetadata -PointPath $PointPath -PointId $id -Protected $Protected -Verified $true `
        -DatabaseTimestamp ([DateTimeOffset]$db.LastWriteTime) -DatabaseSha256 $hash -DatabaseSize $db.Length `
        -DeviceInfo $null -MediaFileCount $null -MediaBytes $null -MediaManifestCaptured $false
}

function Invoke-Organize {
    Write-Section 'ORGANIZE EXISTING BACKUPS'
    Ensure-Directory $Config.RecoveryPointsPath
    Ensure-Directory $Config.SharedMediaPath

    $sources = @()
    $legacyRoots = @(
        (Join-Path $Config.RootPath 'archives'),
        (Join-Path $Config.RootPath 'migrations')
    )

    foreach ($legacyRoot in $legacyRoots) {
        if (-not (Test-Path -LiteralPath $legacyRoot)) { continue }
        foreach ($bucket in Get-ChildItem -LiteralPath $legacyRoot -Directory) {
            $wa = Join-Path $bucket.FullName 'WhatsApp'
            if (Test-Path -LiteralPath $wa) {
                $sources += [pscustomobject]@{
                    Path=$wa
                    LegacyRoot=$legacyRoot
                    Bucket=$bucket.FullName
                    Protected=($legacyRoot -like '*\archives') -or ($bucket.Name -match 'rescue|archive')
                }
            }
        }
    }

    if ($sources.Count -eq 0) {
        Write-Info 'No legacy archives/migrations with a WhatsApp directory were found.'
    }

    foreach ($src in $sources) {
        $id = Get-PointIdFromDatabase $src.Path
        if (-not $id) {
            Write-Warn "Skipping $($src.Path): no current full database found."
            continue
        }

        $target = Join-Path $Config.RecoveryPointsPath $id
        if (Test-Path -LiteralPath $target) {
            Write-Warn "Target already exists; leaving source untouched: $target"
            continue
        }

        Write-Info "Moving $($src.Path) -> $target"
        Move-Item -LiteralPath $src.Path -Destination $target
        Ensure-MediaJunction $target
        Initialize-MetadataForExistingPoint -PointPath $target -Protected $src.Protected

        if (Test-Path -LiteralPath $src.Bucket) {
            $remaining = @(Get-ChildItem -LiteralPath $src.Bucket -Force -ErrorAction SilentlyContinue)
            if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $src.Bucket -Force }
        }
    }

    foreach ($legacyRoot in $legacyRoots) {
        if (Test-Path -LiteralPath $legacyRoot) {
            $remaining = @(Get-ChildItem -LiteralPath $legacyRoot -Force -ErrorAction SilentlyContinue)
            if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $legacyRoot -Force }
        }
    }

    Write-Ok 'Organization pass completed.'
    Show-RecoveryPoints
}

function Wait-ForFreshDatabase {
    while ($true) {
        $db = Get-RemoteDatabaseInfo
        if ($db -and $db.Size -gt 1MB -and $db.Age.TotalHours -le $Config.MaxBackupAgeHours) {
            Write-Ok "Fresh full database found: $(Format-Bytes $db.Size), $($db.Timestamp.ToString('yyyy-MM-dd HH:mm:ss')), age $(Format-Age $db.Age)."
            return $db
        }

        if (-not $db) { Write-Warn 'Current full msgstore.db.crypt14 was not found.' }
        else { Write-Warn "Current full database is $(Format-Age $db.Age) old; limit is $($Config.MaxBackupAgeHours)h." }

        Write-Host ''
        Write-Host 'On the phone, open:'
        Write-Host '  WhatsApp -> Settings -> Chats -> Chat backup -> Back up'
        Write-Host 'Wait until WhatsApp says the backup has completed.'
        $answer = Read-Host 'Press ENTER to re-check, or type Q to abort'
        if ($answer -match '^[Qq]$') { throw 'Backup creation aborted by user.' }
    }
}

function Get-UniqueRecoveryPointPath {
    param([DateTimeOffset]$DatabaseTimestamp)
    $baseId = $DatabaseTimestamp.ToString('yyyy-MM-dd_HHmm')
    $candidate = Join-Path $Config.RecoveryPointsPath $baseId
    if (-not (Test-Path -LiteralPath $candidate)) {
        return [pscustomobject]@{ Id=$baseId; Path=$candidate }
    }

    $i = 2
    while ($true) {
        $id = "$baseId-$i"
        $p = Join-Path $Config.RecoveryPointsPath $id
        if (-not (Test-Path -LiteralPath $p)) { return [pscustomobject]@{ Id=$id; Path=$p } }
        $i++
    }
}

function Prune-RecoveryDatabases {
    param([string]$DatabaseDirectory)

    if (-not $Config.KeepFallbackDatabaseChain) {
        foreach ($file in Get-ChildItem -LiteralPath $DatabaseDirectory -File -ErrorAction SilentlyContinue) {
            if ($file.Name -ne 'msgstore.db.crypt14' -and $file.Name -match '^msgstore-.*\.db\.crypt14$') {
                Remove-Item -LiteralPath $file.FullName -Force
            }
        }
        Write-Info 'Database history normalized: kept only msgstore.db.crypt14.'
        return
    }

    $datedFull = @(Get-ChildItem -LiteralPath $DatabaseDirectory -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^msgstore-\d{4}-\d{2}-\d{2}\.1\.db\.crypt14$' } |
        Sort-Object LastWriteTime -Descending)

    if ($datedFull.Count -le 1) { return }

    $fallback = $datedFull[0]
    if ($fallback.Name -match '^msgstore-(\d{4}-\d{2}-\d{2})\.1\.db\.crypt14$') {
        $fallbackDate = $Matches[1]
    } else { return }

    foreach ($file in Get-ChildItem -LiteralPath $DatabaseDirectory -File) {
        if ($file.Name -eq 'msgstore.db.crypt14') { continue }
        if ($file.Name -eq $fallback.Name) { continue }
        if ($file.Name -match "^msgstore-increment-\d+-$([regex]::Escape($fallbackDate))\.1\.db\.crypt14$") { continue }
        if ($file.Name -match '^msgstore-.*\.db\.crypt14$') {
            Remove-Item -LiteralPath $file.FullName -Force
        }
    }

    Write-Info "Database history normalized: kept current full DB + fallback chain based on $fallbackDate."
}

function Get-RemoteMediaManifest {
    Write-Info 'Scanning phone Media file list and sizes...'
    $remote = "$($Config.RemoteWhatsAppPath)/Media"
    # Toybox find supports '{} +' batching, avoiding one stat process per file.
    $command = "find '$remote' -type f -exec stat -c '%s|%n' {} +"
    $lines = Invoke-AdbText -Arguments @('shell', $command)

    $list = New-Object System.Collections.Generic.List[object]
    foreach ($raw in $lines) {
        $line = ([string]$raw).TrimEnd("`r")
        $idx = $line.IndexOf('|')
        if ($idx -lt 1) { continue }
        $sizeText = $line.Substring(0,$idx)
        $full = $line.Substring($idx+1)
        [Int64]$size = 0
        if (-not [Int64]::TryParse($sizeText,[ref]$size)) { continue }
        if (-not $full.StartsWith($remote)) { continue }
        $rel = $full.Substring($remote.Length).TrimStart('/')
        if (-not $rel) { continue }
        $list.Add([pscustomobject]@{ Path=$rel; Size=$size; RemotePath=$full })
    }
    return @($list)
}

function Get-LocalMediaMap {
    # Normal PowerShell hashtables are case-insensitive, which matches Windows path behavior.
    $map = @{}
    if (-not (Test-Path -LiteralPath $Config.SharedMediaPath)) { return $map }
    $base = $Config.SharedMediaPath.TrimEnd('\')
    foreach ($file in Get-ChildItem -LiteralPath $Config.SharedMediaPath -Recurse -File -Force -ErrorAction SilentlyContinue) {
        $rel = $file.FullName.Substring($base.Length).TrimStart('\').Replace('\','/')
        $map[$rel] = [Int64]$file.Length
    }
    return $map
}

function Write-MediaManifest {
    param([string]$PointPath,[object[]]$Manifest)
    $path = Join-Path $PointPath 'media-manifest.tsv'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $writer = New-Object System.IO.StreamWriter($path,$false,$utf8NoBom)
    try {
        $writer.WriteLine("Size`tPath")
        foreach ($item in ($Manifest | Sort-Object Path)) {
            $safePath = ([string]$item.Path).Replace("`t",' ')
            $writer.WriteLine("$($item.Size)`t$safePath")
        }
    } finally {
        $writer.Dispose()
    }
}

function Sync-MediaFromPhone {
    param([string]$PointPath)
    Ensure-Directory (Split-Path -Parent $Config.SharedMediaPath)

    $remote = "$($Config.RemoteWhatsAppPath)/Media"
    $manifest = Get-RemoteMediaManifest
    if ($manifest.Count -eq 0) {
        Write-Warn 'Phone Media manifest is empty. No media transfer performed.'
        return [pscustomobject]@{ Manifest=$manifest; FileCount=0; Bytes=0 }
    }

    [Int64]$remoteBytes = 0
    foreach ($m in $manifest) { $remoteBytes += [Int64]$m.Size }
    Write-Info "Phone Media: $($manifest.Count) files, $(Format-Bytes $remoteBytes)."

    if (-not (Test-Path -LiteralPath $Config.SharedMediaPath)) {
        Write-Info 'No shared Media archive exists; performing initial full pull.'
        $parent = Split-Path -Parent $Config.SharedMediaPath
        Ensure-Directory $parent
        Invoke-AdbInteractive -Arguments @('pull','-a',$remote,$parent)
    } else {
        $localMap = Get-LocalMediaMap
        Write-Info "Local Media: $($localMap.Count) files. Comparing by relative path + size."

        $need = New-Object System.Collections.Generic.List[object]
        [Int64]$needBytes = 0
        foreach ($item in $manifest) {
            $has = $localMap.ContainsKey($item.Path)
            if ((-not $has) -or ($localMap[$item.Path] -ne [Int64]$item.Size)) {
                $need.Add($item)
                $needBytes += [Int64]$item.Size
            }
        }

        $remoteSet = @{}
        foreach ($item in $manifest) { $remoteSet[$item.Path] = $true }
        $archivedOnly = 0
        foreach ($key in $localMap.Keys) { if (-not $remoteSet.ContainsKey($key)) { $archivedOnly++ } }

        Write-Host "Need transfer: $($need.Count) files, $(Format-Bytes $needBytes)"
        Write-Host "Archived-only: $archivedOnly local files (retained; backup is not a mirror)."

        if ($need.Count -gt 0) {
            $mode = 'selective'
            if ($need.Count -gt $Config.SelectivePullMaxFiles) {
                Write-Warn "Selective pull needs $($need.Count) adb file transfers (configured threshold: $($Config.SelectivePullMaxFiles))."
                Write-Host '[S] Selective: transfer only missing/size-changed files'
                Write-Host '[B] Bulk: re-pull the entire Media tree'
                Write-Host '[Q] Abort media sync'
                $answer = Read-Host 'Choose S/B/Q (default S)'
                if ($answer -match '^[Bb]$') { $mode='bulk' }
                elseif ($answer -match '^[Qq]$') { throw 'Media sync aborted by user.' }
            }

            if ($mode -eq 'bulk') {
                $parent = Split-Path -Parent $Config.SharedMediaPath
                Invoke-AdbInteractive -Arguments @('pull','-a',$remote,$parent)
            } else {
                $i = 0
                foreach ($item in $need) {
                    $i++
                    $localFile = Join-Path $Config.SharedMediaPath ($item.Path.Replace('/','\'))
                    Ensure-Directory (Split-Path -Parent $localFile)
                    Write-Host "[$i/$($need.Count)] $($item.Path)"
                    Invoke-AdbInteractive -Arguments @('pull','-a',$item.RemotePath,$localFile)
                }
            }
        } else {
            Write-Ok 'Shared Media archive is already up to date.'
        }
    }

    Write-MediaManifest -PointPath $PointPath -Manifest $manifest
    return [pscustomobject]@{ Manifest=$manifest; FileCount=[Int64]$manifest.Count; Bytes=$remoteBytes }
}

function Invoke-CreateBackup {
    Write-Section 'CREATE RECOVERY POINT'
    Ensure-Directory $Config.RecoveryPointsPath
    Ensure-Directory (Split-Path -Parent $Config.SharedMediaPath)

    $device = Get-DeviceInfo
    Write-Host "Source device: $($device.Manufacturer) $($device.Model) ($($device.Serial))"

    [void](Wait-ForFreshDatabase)

    Write-Info 'Force-stopping WhatsApp for a stable final snapshot...'
    Invoke-AdbText -Arguments @('shell','am force-stop com.whatsapp') | Out-Null
    Start-Sleep -Milliseconds 600

    $db = Get-RemoteDatabaseInfo
    if (-not $db) { throw 'Full database disappeared after force-stop.' }
    if ($db.Age.TotalHours -gt $Config.MaxBackupAgeHours) { throw 'Database became stale unexpectedly; aborting.' }

    Write-Info 'Hashing the full database on the phone for end-to-end verification...'
    $remoteHash = Get-RemoteSha256 $db.Path
    if ($remoteHash) { Write-Ok "Phone database SHA256: $remoteHash" }
    else { Write-Warn 'Phone-side SHA256 was unavailable; size/hash checks will be local only.' }

    # If an imported recovery point already represents this exact full database,
    # enrich it with a Media manifest instead of creating a duplicate snapshot.
    $baseId = $db.Timestamp.ToString('yyyy-MM-dd_HHmm')
    $basePath = Join-Path $Config.RecoveryPointsPath $baseId
    $reuseExisting = $false
    $point = $null

    if (Test-Path -LiteralPath $basePath) {
        $existingDbPath = Join-Path $basePath 'Databases\msgstore.db.crypt14'
        if (Test-Path -LiteralPath $existingDbPath) {
            $existingDb = Get-Item -LiteralPath $existingDbPath
            if ($existingDb.Length -eq $db.Size) {
                $existingHash = (Get-FileHash -LiteralPath $existingDbPath -Algorithm SHA256).Hash
                if ((-not $remoteHash) -or ($existingHash -eq $remoteHash)) {
                    $point = [pscustomobject]@{ Id=$baseId; Path=$basePath }
                    $reuseExisting = $true
                    Write-Info "Existing recovery point matches the phone full database; enriching it instead of duplicating it: $baseId"
                } else {
                    Write-Warn 'Existing same-timestamp recovery point has a different SHA256; a new suffixed point will be created.'
                }
            }
        }
    }

    if (-not $point) { $point = Get-UniqueRecoveryPointPath $db.Timestamp }
    Ensure-Directory $point.Path
    Write-Info "Recovery point: $($point.Id)"

    try {
        if (-not $reuseExisting) {
            Invoke-AdbInteractive -Arguments @('pull','-a',"$($Config.RemoteWhatsAppPath)/Backups",$point.Path)
            Invoke-AdbInteractive -Arguments @('pull','-a',"$($Config.RemoteWhatsAppPath)/Databases",$point.Path)
        }

        $localDb = Join-Path $point.Path 'Databases\msgstore.db.crypt14'
        if (-not (Test-Path -LiteralPath $localDb)) { throw 'Recovery point does not contain msgstore.db.crypt14.' }

        $localDbItem = Get-Item -LiteralPath $localDb
        if ($localDbItem.Length -ne $db.Size) {
            throw "Database size mismatch. Phone=$($db.Size), PC=$($localDbItem.Length)."
        }

        $hash = (Get-FileHash -LiteralPath $localDb -Algorithm SHA256).Hash
        if ($remoteHash -and $hash -ne $remoteHash) {
            throw "Database SHA256 mismatch after capture. Phone=$remoteHash PC=$hash"
        }
        Write-Ok "Database verified and hashed: $(Format-Bytes $localDbItem.Length), SHA256 $hash"

        $existingMeta = Read-RecoveryMetadata $point.Path
        $protected = ($Config.ProtectedRecoveryPointIds -contains $point.Id)
        if ($existingMeta -and $existingMeta.Protected -ne $null) { $protected = [bool]$existingMeta.Protected }

        # Preserve the pulled database set during capture. Database-history pruning is
        # deliberately an explicit cleanup action, not part of backup creation.
        Ensure-MediaJunction $point.Path
        $media = Sync-MediaFromPhone -PointPath $point.Path

        Write-RecoveryMetadata -PointPath $point.Path -PointId $point.Id -Protected $protected -Verified $true `
            -DatabaseTimestamp $db.Timestamp -DatabaseSha256 $hash -DatabaseSize $localDbItem.Length `
            -DeviceInfo $device -MediaFileCount $media.FileCount -MediaBytes $media.Bytes -MediaManifestCaptured $true

        if ($reuseExisting) { Write-Ok "Existing recovery point enriched and verified: $($point.Path)" }
        else { Write-Ok "Recovery point created: $($point.Path)" }
    } catch {
        Write-Fail $_.Exception.Message
        Write-Warn "Recovery point retained for inspection: $($point.Path)"
        throw
    }
}

function Resolve-RecoveryPoint {
    param([string]$Requested)
    $dirs = Get-RecoveryPointDirectories
    if ($dirs.Count -eq 0) { throw 'No recovery points exist.' }

    if ($Requested) {
        $match = @($dirs | Where-Object { $_.Name -eq $Requested })
        if ($match.Count -ne 1) { throw "Recovery point '$Requested' not found." }
        return $match[0]
    }

    Write-Host 'Available recovery points:'
    for ($i=0; $i -lt $dirs.Count; $i++) { Write-Host "[$($i+1)] $($dirs[$i].Name)" }
    $answer = Read-Host 'Select recovery point number'
    [int]$index = 0
    if (-not [int]::TryParse($answer,[ref]$index) -or $index -lt 1 -or $index -gt $dirs.Count) {
        throw 'Invalid recovery point selection.'
    }
    return $dirs[$index-1]
}

function Test-RecoveryPoint {
    param([System.IO.DirectoryInfo]$Point,[switch]$Deep)
    Write-Section "VERIFY $($Point.Name)"
    $ok = $true
    $meta = Read-RecoveryMetadata $Point.FullName
    $dbPath = Join-Path $Point.FullName 'Databases\msgstore.db.crypt14'
    $backups = Join-Path $Point.FullName 'Backups'

    if (-not (Test-Path -LiteralPath $dbPath)) { Write-Fail 'Missing msgstore.db.crypt14'; $ok=$false }
    else {
        $db = Get-Item -LiteralPath $dbPath
        Write-Ok "Database present: $(Format-Bytes $db.Length)"
        if ($meta -and $meta.DatabaseSha256) {
            $hash = (Get-FileHash -LiteralPath $dbPath -Algorithm SHA256).Hash
            if ($hash -eq [string]$meta.DatabaseSha256) { Write-Ok 'Database SHA256 matches recovery.json.' }
            else { Write-Fail 'Database SHA256 mismatch.'; $ok=$false }
        } else { Write-Warn 'No stored database SHA256 metadata.' }
    }

    if (Test-Path -LiteralPath $backups) { Write-Ok 'Backups directory present.' }
    else { Write-Fail 'Backups directory missing.'; $ok=$false }

    if (Test-Path -LiteralPath $Config.SharedMediaPath) { Write-Ok 'Shared Media repository present.' }
    else { Write-Fail 'Shared Media repository missing.'; $ok=$false }

    $manifestPath = Join-Path $Point.FullName 'media-manifest.tsv'
    if (Test-Path -LiteralPath $manifestPath) {
        Write-Ok 'Media manifest present.'
        if ($Deep) {
            Write-Info 'Deep-verifying all media paths and sizes in this recovery point...'
            $missing=0; $badSize=0; $count=0
            foreach ($line in Get-Content -LiteralPath $manifestPath | Select-Object -Skip 1) {
                $idx = $line.IndexOf("`t")
                if ($idx -lt 1) { continue }
                [Int64]$size=0
                if (-not [Int64]::TryParse($line.Substring(0,$idx),[ref]$size)) { continue }
                $rel=$line.Substring($idx+1)
                $local=Join-Path $Config.SharedMediaPath ($rel.Replace('/','\'))
                $count++
                if (-not (Test-Path -LiteralPath $local)) { $missing++; continue }
                if ((Get-Item -LiteralPath $local).Length -ne $size) { $badSize++ }
            }
            if ($missing -eq 0 -and $badSize -eq 0) { Write-Ok "Deep media verification passed for $count files." }
            else { Write-Fail "Media verification: $missing missing, $badSize wrong-size files."; $ok=$false }
        }
    } else { Write-Warn 'No point-in-time Media manifest (expected for imported legacy recovery points).' }

    if ($ok) { Write-Ok 'Recovery point verification PASSED.' }
    else { Write-Fail 'Recovery point verification FAILED.' }
    return $ok
}

function Invoke-Verify {
    $point = Resolve-RecoveryPoint $RecoveryPoint
    [void](Test-RecoveryPoint -Point $point -Deep:$DeepVerify)
}

function Invoke-Cleanup {
    $point = Resolve-RecoveryPoint $RecoveryPoint
    $summary = Get-RecoveryPointSummary $point
    Write-Section "CLEANUP $($point.Name)"
    if ($summary.Protected) {
        throw 'This recovery point is protected. Cleanup will not modify it.'
    }
    Write-Warn 'Cleanup only removes older dated/incremental database chains inside this PC recovery point.'
    Write-Host 'It does NOT delete phone data, Backups, shared Media, or msgstore.db.crypt14.'
    $answer = Read-Host "Type CLEAN to continue"
    if ($answer -ne 'CLEAN') { throw 'Cleanup cancelled.' }
    Prune-RecoveryDatabases -DatabaseDirectory (Join-Path $point.FullName 'Databases')
    Write-Ok 'Cleanup completed.'
}

function Repair-DestinationMediaFromManifest {
    param([System.IO.DirectoryInfo]$Point)

    $manifestPath = Join-Path $Point.FullName 'media-manifest.tsv'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        Write-Warn 'This recovery point has no point-in-time Media manifest; exact destination Media verification is unavailable.'
        return
    }

    Write-Info 'Verifying destination Media against the recovery-point manifest...'
    $expected = @{}
    foreach ($line in Get-Content -LiteralPath $manifestPath | Select-Object -Skip 1) {
        $idx = $line.IndexOf("`t")
        if ($idx -lt 1) { continue }
        [Int64]$size=0
        if (-not [Int64]::TryParse($line.Substring(0,$idx),[ref]$size)) { continue }
        $rel = $line.Substring($idx+1)
        $expected[$rel] = $size
    }

    $remoteManifest = Get-RemoteMediaManifest
    $remoteMap = @{}
    foreach ($item in $remoteManifest) { $remoteMap[$item.Path] = [Int64]$item.Size }

    $repair = New-Object System.Collections.Generic.List[string]
    foreach ($rel in $expected.Keys) {
        if ((-not $remoteMap.ContainsKey($rel)) -or ($remoteMap[$rel] -ne $expected[$rel])) {
            $repair.Add($rel)
        }
    }

    if ($repair.Count -eq 0) {
        Write-Ok "Destination Media verification passed for $($expected.Count) manifest files."
        return
    }

    Write-Warn "$($repair.Count) Media files are missing or have the wrong size after --sync; repairing them explicitly."
    $i=0
    foreach ($rel in $repair) {
        $i++
        $localFile = Join-Path $Config.SharedMediaPath ($rel.Replace('/','\'))
        if (-not (Test-Path -LiteralPath $localFile)) {
            throw "Shared Media is missing a file required by the recovery manifest: $rel"
        }
        $remoteFile = "$($Config.RemoteWhatsAppPath)/Media/$rel"
        $slash = $remoteFile.LastIndexOf('/')
        if ($slash -gt 0) {
            $remoteParent = $remoteFile.Substring(0,$slash)
            Invoke-AdbText -Arguments @('shell',"mkdir -p '$remoteParent'") | Out-Null
        }
        Write-Host "[repair $i/$($repair.Count)] $rel"
        Invoke-AdbInteractive -Arguments @('push',$localFile,$remoteFile)
        $remoteInfo = Get-RemoteFileInfo $remoteFile
        if (-not $remoteInfo -or $remoteInfo.Size -ne $expected[$rel]) {
            throw "Media repair verification failed: $rel"
        }
    }
    Write-Ok "Destination Media repaired and verified for $($repair.Count) files."
}

function Invoke-RestorePrep {
    $point = Resolve-RecoveryPoint $RecoveryPoint
    if (-not (Test-RecoveryPoint -Point $point)) { throw 'Recovery point verification failed; restore preparation aborted.' }

    Write-Section "RESTORE PREPARATION: $($point.Name)"
    $device = Get-DeviceInfo
    Write-Host "Destination device: $($device.Manufacturer) $($device.Model) ($($device.Serial))"

    $pm = Invoke-AdbText -Arguments @('shell','pm path com.whatsapp') -AllowFailure
    if (-not (($pm -join '') -match 'package:')) {
        throw 'WhatsApp is not installed on the destination phone. Install it, open only to the initial setup screen, then run restore-prep again.'
    }

    Write-Warn 'This mode writes WhatsApp shared-storage files to the connected phone.'
    Write-Host 'Use it only before WhatsApp has begun restoring/processing a backup.'
    Write-Host 'It does not clear private app data or uninstall WhatsApp.'
    $answer = Read-Host 'Type RESTORE to continue'
    if ($answer -ne 'RESTORE') { throw 'Restore preparation cancelled.' }

    Invoke-AdbText -Arguments @('shell','am force-stop com.whatsapp') | Out-Null
    $remote = $Config.RemoteWhatsAppPath
    Invoke-AdbText -Arguments @('shell',"mkdir -p '$remote/Backups' '$remote/Databases' '$remote/Media'") | Out-Null

    $backups = Join-Path $point.FullName 'Backups'
    $db = Join-Path $point.FullName 'Databases\msgstore.db.crypt14'

    Write-Info 'Syncing Backups to phone...'
    Invoke-AdbInteractive -Arguments @('push','--sync',$backups,"$remote/")

    Write-Info 'Placing selected full database explicitly...'
    Invoke-AdbInteractive -Arguments @('push',$db,"$remote/Databases/msgstore.db.crypt14")

    Write-Info 'Syncing shared Media to phone with adb push --sync...'
    Invoke-AdbInteractive -Arguments @('push','--sync',$Config.SharedMediaPath,"$remote/")
    Repair-DestinationMediaFromManifest -Point $point

    $remoteDb = Get-RemoteDatabaseInfo
    $localDb = Get-Item -LiteralPath $db
    if (-not $remoteDb -or $remoteDb.Size -ne $localDb.Length) {
        throw 'Remote database size verification failed after push.'
    }
    $localHash = (Get-FileHash -LiteralPath $db -Algorithm SHA256).Hash
    $remoteHash = Get-RemoteSha256 $remoteDb.Path
    if ($remoteHash -and $remoteHash -ne $localHash) {
        throw "Remote database SHA256 verification failed. PC=$localHash phone=$remoteHash"
    }
    if ($remoteHash) { Write-Ok 'Remote database SHA256 matches the selected recovery point.' }
    else { Write-Warn 'Destination phone SHA256 unavailable; database size matched.' }

    Write-Ok 'Restore files are prepared on the destination phone.'
    Write-Host ''
    Write-Host 'NEXT:'
    Write-Host '  1. Open WhatsApp.'
    Write-Host '  2. Verify the same phone number.'
    Write-Host '  3. Confirm it detects the intended LOCAL backup.'
    Write-Host '  4. Choose Restore.'
    Write-Host ''
    Write-Warn 'Once WhatsApp starts restoring, DO NOT run restore-prep again unless intentionally restarting the restore attempt.'
}

function Show-Status {
    try {
        Show-DeviceAndBackupStatus
    } catch {
        Write-Section 'PHONE STATUS'
        Write-Warn "Phone/ADB status unavailable: $($_.Exception.Message)"
        Write-Info 'Local recovery-point inventory will still be shown.'
    }
    Show-RecoveryPoints

    Write-Section 'LOCAL STORAGE'
    if (Test-Path -LiteralPath $Config.SharedMediaPath) {
        [Int64]$bytes = 0
        [Int64]$count = 0
        foreach ($f in Get-ChildItem -LiteralPath $Config.SharedMediaPath -Recurse -File -Force -ErrorAction SilentlyContinue) {
            $count++
            $bytes += [Int64]$f.Length
        }
        Write-Host "Shared Media: $count files, $(Format-Bytes $bytes)"
    } else {
        Write-Host 'Shared Media: not created yet'
    }
    Write-Host "Root:         $($Config.RootPath)"
    Write-Host "ADB:          $script:AdbPath"
}

function Show-Menu {
    while ($true) {
        Write-Section "WhatsApp Backup Manager v$ScriptVersion"
        Write-Host '[1] Status'
        Write-Host '[2] Create recovery point'
        Write-Host '[3] List recovery points'
        Write-Host '[4] Verify recovery point'
        Write-Host '[5] Prepare restore to connected phone'
        Write-Host '[6] Organize legacy archives/migrations'
        Write-Host '[7] Cleanup a recovery point'
        Write-Host '[8] Exit'
        $choice = Read-Host 'Choose'
        try {
            switch ($choice) {
                '1' { Show-Status }
                '2' { Invoke-CreateBackup }
                '3' { Show-RecoveryPoints }
                '4' { Invoke-Verify }
                '5' { Invoke-RestorePrep }
                '6' { Invoke-Organize }
                '7' { Invoke-Cleanup }
                '8' { return }
                default { Write-Warn 'Unknown menu choice.' }
            }
        } catch {
            Write-Fail $_.Exception.Message
        }
    }
}

try {
    switch ($Action) {
        'menu'         { Show-Menu }
        'status'       { Show-Status }
        'organize'     { Invoke-Organize }
        'backup'       { Invoke-CreateBackup }
        'list'         { Show-RecoveryPoints }
        'verify'       { Invoke-Verify }
        'restore-prep' { Invoke-RestorePrep }
        'cleanup'      { Invoke-Cleanup }
    }
} catch {
    Write-Fail $_.Exception.Message
    exit 1
}
