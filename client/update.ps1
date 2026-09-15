#Requires -Version 5.1
# DRUZHBODOM_UPDATER_SELFUPDATE_V1
[CmdletBinding()]
param(
    [switch]$NoLaunch,
    [switch]$ForceUpdate,
    [switch]$EnableLowSpec,
    [switch]$DisableLowSpec,
    [switch]$SkipSelfUpdate,
    [string]$GitHubRepo = 'idontknowhowbut/valheim-modpack-druzhbodom'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

if ($EnableLowSpec -and $DisableLowSpec) {
    throw 'Use either -EnableLowSpec or -DisableLowSpec, not both.'
}

$AppName = 'DruzhbodomValheim'
$SteamAppId = 892970
$StateRoot = Join-Path $env:APPDATA $AppName
$ConfigPath = Join-Path $StateRoot 'launcher.json'
$LocalStatePath = Join-Path $StateRoot 'modpack-state.json'

function Write-Step([string]$Text) {
    Write-Host "`n==> $Text" -ForegroundColor Cyan
}

function Ensure-StateRoot {
    New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
}

function Select-Folder([string]$Description, [string]$InitialDirectory) {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = $true
    if ($InitialDirectory -and (Test-Path -LiteralPath $InitialDirectory)) {
        $dialog.SelectedPath = $InitialDirectory
    }
    $result = $dialog.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        throw 'Folder selection cancelled.'
    }
    return $dialog.SelectedPath
}

function Get-SteamInstallPath {
    $candidates = New-Object System.Collections.Generic.List[string]

    try {
        $reg = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction Stop
        if ($reg.SteamPath) { $candidates.Add([string]$reg.SteamPath) }
    } catch {}

    try {
        $reg32 = Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction Stop
        if ($reg32.InstallPath) { $candidates.Add([string]$reg32.InstallPath) }
    } catch {}

    $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Steam'))

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'steam.exe'))) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Get-SteamLibraries([string]$SteamRoot) {
    $libraries = New-Object System.Collections.Generic.List[string]
    if ($SteamRoot) { $libraries.Add($SteamRoot) }

    $vdf = Join-Path $SteamRoot 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        foreach ($line in Get-Content -LiteralPath $vdf) {
            if ($line -match '^\s*"path"\s*"([^"]+)"') {
                $path = $matches[1].Replace('\\', '\')
                $libraries.Add($path)
            }
            elseif ($line -match '^\s*"\d+"\s*"([^"]+)"') {
                $path = $matches[1].Replace('\\', '\')
                $libraries.Add($path)
            }
        }
    }

    return $libraries | Select-Object -Unique
}

function Find-ValheimPath([string]$SteamRoot) {
    if (-not $SteamRoot) { return $null }
    foreach ($library in Get-SteamLibraries $SteamRoot) {
        $candidate = Join-Path $library 'steamapps\common\Valheim'
        if (Test-Path -LiteralPath (Join-Path $candidate 'valheim.exe')) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Save-LauncherConfig([object]$Config) {
    [System.IO.File]::WriteAllText($ConfigPath, ($Config | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
}

function Get-ConfiguredAddons([object]$Config) {
    $prop = $Config.PSObject.Properties['addons']
    if (-not $prop -or $null -eq $prop.Value) {
        return @()
    }

    return @(
        $prop.Value |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
}

function Ask-LowSpecPreference {
    $answer = Read-Host 'Enable low-spec optimization addon? [y/N]'
    return ($answer -match '^(y|yes|д|да)$')
}

function New-LauncherConfig {
    Ensure-StateRoot

    Write-Host 'First run detected.' -ForegroundColor Yellow
    $defaultProfile = Join-Path $StateRoot 'profile'
    Write-Host "Default modpack directory: $defaultProfile"
    $answer = Read-Host 'Use this directory? [Y/n]'
    if ([string]::IsNullOrWhiteSpace($answer) -or $answer -match '^(y|yes|д|да)$') {
        $profileDir = $defaultProfile
    }
    else {
        $profileDir = Select-Folder -Description 'Choose directory where the Druzhbodom modpack profile will be stored' -InitialDirectory $StateRoot
        $profileDir = Join-Path $profileDir 'DruzhbodomProfile'
    }

    $steamRoot = Get-SteamInstallPath
    $gameDir = Find-ValheimPath $steamRoot

    if ($gameDir) {
        Write-Host "Found Valheim: $gameDir"
        $useFound = Read-Host 'Use this installation? [Y/n]'
        if (-not ([string]::IsNullOrWhiteSpace($useFound) -or $useFound -match '^(y|yes|д|да)$')) {
            $gameDir = $null
        }
    }

    if (-not $gameDir) {
        $gameDir = Select-Folder -Description 'Choose the Valheim game directory (the folder containing valheim.exe)' -InitialDirectory $steamRoot
        if (-not (Test-Path -LiteralPath (Join-Path $gameDir 'valheim.exe'))) {
            throw "valheim.exe was not found in: $gameDir"
        }
    }

    if (-not $steamRoot) {
        $steamExe = Select-Folder -Description 'Choose the Steam installation directory (the folder containing steam.exe)' -InitialDirectory $env:ProgramFiles
        if (-not (Test-Path -LiteralPath (Join-Path $steamExe 'steam.exe'))) {
            throw 'steam.exe was not found in the selected directory.'
        }
        $steamRoot = $steamExe
    }

    $addons = @()
    if (Ask-LowSpecPreference) {
        $addons += 'low-spec'
    }

    $config = [ordered]@{
        profileDir = [System.IO.Path]::GetFullPath($profileDir)
        gameDir    = [System.IO.Path]::GetFullPath($gameDir)
        steamRoot  = [System.IO.Path]::GetFullPath($steamRoot)
        addons     = @($addons)
    }
    $configObject = [pscustomobject]$config
    Save-LauncherConfig $configObject
    return $configObject
}

function Get-LauncherConfig {
    Ensure-StateRoot
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return New-LauncherConfig
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if (-not $config.profileDir -or -not $config.gameDir -or -not $config.steamRoot) {
        throw "Invalid launcher config: $ConfigPath"
    }

    # Migration for configs created by older launcher versions. Ask once, then
    # persist the addon choice in launcher.json.
    if (-not $config.PSObject.Properties['addons']) {
        $addons = @()
        Write-Host 'Launcher config was created before addon support.' -ForegroundColor Yellow
        if (Ask-LowSpecPreference) {
            $addons += 'low-spec'
        }
        Add-Member -InputObject $config -NotePropertyName addons -NotePropertyValue @($addons)
        Save-LauncherConfig $config
    }

    return $config
}

function Set-LowSpecPreference([object]$Config, [bool]$Enabled) {
    $addons = @(Get-ConfiguredAddons $Config | Where-Object { $_ -ne 'low-spec' })
    if ($Enabled) {
        $addons += 'low-spec'
    }
    $Config.addons = @($addons | Sort-Object -Unique)
    Save-LauncherConfig $Config
    Write-Host ("Low-spec addon: {0}" -f $(if ($Enabled) { 'enabled' } else { 'disabled' })) -ForegroundColor Green
}

function Format-ByteSize([long]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GiB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MiB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KiB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Download-File(
    [string]$Uri,
    [string]$OutFile,
    [string]$Label = 'Downloading',
    [switch]$ShowProgress
) {
    Add-Type -AssemblyName System.Net.Http

    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('valheim-modpack-druzhbodom-client')

    $response = $null
    $input = $null
    $output = $null
    try {
        $response = $client.GetAsync($Uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw "HTTP $([int]$response.StatusCode) $($response.ReasonPhrase): $Uri"
        }

        $total = -1L
        if ($null -ne $response.Content.Headers.ContentLength) {
            $total = [long]$response.Content.Headers.ContentLength
        }

        $input = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $output = [System.IO.File]::Open(
            $OutFile,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )

        $buffer = New-Object byte[] 131072
        $downloaded = 0L
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $lastProgressMs = -1000L

        while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $output.Write($buffer, 0, $read)
            $downloaded += $read

            if ($ShowProgress -and ($stopwatch.ElapsedMilliseconds - $lastProgressMs -ge 150)) {
                $lastProgressMs = $stopwatch.ElapsedMilliseconds
                $elapsedSeconds = [Math]::Max($stopwatch.Elapsed.TotalSeconds, 0.001)
                $speed = [long]($downloaded / $elapsedSeconds)

                if ($total -gt 0) {
                    $percent = [Math]::Min(100, [int](($downloaded * 100.0) / $total))
                    $status = "$(Format-ByteSize $downloaded) / $(Format-ByteSize $total)  |  $(Format-ByteSize $speed)/s"
                    Write-Progress -Activity $Label -Status $status -PercentComplete $percent
                }
                else {
                    $status = "$(Format-ByteSize $downloaded)  |  $(Format-ByteSize $speed)/s"
                    Write-Progress -Activity $Label -Status $status
                }
            }
        }

        if ($ShowProgress) {
            Write-Progress -Activity $Label -Completed
            Write-Host ("Downloaded {0}." -f (Format-ByteSize $downloaded)) -ForegroundColor Green
        }
    }
    finally {
        if ($output) { $output.Dispose() }
        if ($input) { $input.Dispose() }
        if ($response) { $response.Dispose() }
        $client.Dispose()
        $handler.Dispose()
    }
}

function Invoke-SelfUpdate {
    if ($SkipSelfUpdate) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($PSCommandPath) -or -not (Test-Path -LiteralPath $PSCommandPath -PathType Leaf)) {
        Write-Warning 'Self-update skipped: launcher script path is unavailable.'
        return
    }

    $remoteUrl = "https://raw.githubusercontent.com/$GitHubRepo/main/client/update.ps1"
    $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) ("druzhbodom-update-self-" + [Guid]::NewGuid().ToString('N') + '.ps1')

    try {
        Write-Step 'Checking launcher update'
        Download-File -Uri $remoteUrl -OutFile $tempScript -Label 'Checking launcher update'

        $remoteText = Get-Content -LiteralPath $tempScript -Raw
        if ($remoteText -notmatch 'DRUZHBODOM_UPDATER_SELFUPDATE_V1') {
            throw "Remote file is not a recognized Druzhbodom updater: $remoteUrl"
        }

        $localHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
        $remoteHash = (Get-FileHash -LiteralPath $tempScript -Algorithm SHA256).Hash
        if ($localHash -eq $remoteHash) {
            Write-Host 'Launcher is up to date.' -ForegroundColor DarkGray
            return
        }

        $backupPath = "$PSCommandPath.backup"
        Copy-Item -LiteralPath $PSCommandPath -Destination $backupPath -Force
        Copy-Item -LiteralPath $tempScript -Destination $PSCommandPath -Force
        Write-Host 'Launcher updated. Restarting with the new script...' -ForegroundColor Green

        $restartArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-SkipSelfUpdate')
        if ($NoLaunch) { $restartArgs += '-NoLaunch' }
        if ($ForceUpdate) { $restartArgs += '-ForceUpdate' }
        if ($EnableLowSpec) { $restartArgs += '-EnableLowSpec' }
        if ($DisableLowSpec) { $restartArgs += '-DisableLowSpec' }
        $restartArgs += @('-GitHubRepo', $GitHubRepo)

        & powershell.exe @restartArgs
        exit $LASTEXITCODE
    }
    catch {
        Write-Warning "Launcher self-update check failed; continuing with the current script. $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $tempScript) {
            Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-RemoteManifest([string]$Repo, [string]$TempDir) {
    $manifestPath = Join-Path $TempDir 'manifest.json'
    $uri = "https://github.com/$Repo/releases/latest/download/manifest.json"
    Download-File -Uri $uri -OutFile $manifestPath
    return Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
}

function Get-LocalState {
    if (-not (Test-Path -LiteralPath $LocalStatePath)) { return $null }
    try {
        return Get-Content -LiteralPath $LocalStatePath -Raw | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Get-StateAddons([object]$State) {
    if (-not $State) { return @() }
    $prop = $State.PSObject.Properties['addons']
    if (-not $prop -or $null -eq $prop.Value) { return @() }
    return @($prop.Value | ForEach-Object { [string]$_ } | Sort-Object -Unique)
}

function Test-SameAddons([string[]]$Left, [string[]]$Right) {
    $a = @($Left | Sort-Object -Unique) -join "`n"
    $b = @($Right | Sort-Object -Unique) -join "`n"
    return $a -eq $b
}

function Save-LocalState([string]$Version, [string]$ProfileSha256, [string[]]$Addons) {
    $state = [ordered]@{
        version = $Version
        profileSha256 = $ProfileSha256
        addons = @($Addons | Sort-Object -Unique)
        installedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    [System.IO.File]::WriteAllText($LocalStatePath, ($state | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
}

function Get-ManifestAddon([object]$Manifest, [string]$Name) {
    $addonsProp = $Manifest.PSObject.Properties['addons']
    if (-not $addonsProp -or $null -eq $addonsProp.Value) {
        return $null
    }

    $addonProp = $addonsProp.Value.PSObject.Properties[$Name]
    if (-not $addonProp) {
        return $null
    }
    return $addonProp.Value
}

function Install-Profile([object]$Manifest, [object]$Config, [string]$TempDir, [string]$Repo, [string[]]$Addons) {
    $archive = Join-Path $TempDir 'client-profile.zip'
    $uri = "https://github.com/$Repo/releases/latest/download/$($Manifest.profileAsset)"

    Write-Step "Downloading modpack $($Manifest.version)"
    Download-File -Uri $uri -OutFile $archive -Label "Downloading modpack $($Manifest.version)" -ShowProgress

    Write-Step 'Verifying SHA256'
    $actualHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedHash = ([string]$Manifest.profileSha256).ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "SHA256 mismatch. Expected $expectedHash, got $actualHash"
    }

    $profileDir = [string]$Config.profileDir
    $staging = "$profileDir.__new"
    $backup = "$profileDir.backup"

    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    Write-Step 'Extracting new profile'
    Expand-Archive -LiteralPath $archive -DestinationPath $staging -Force

    foreach ($addonName in $Addons) {
        $addon = Get-ManifestAddon -Manifest $Manifest -Name $addonName
        if (-not $addon) {
            throw "Selected addon '$addonName' is not available in release $($Manifest.version)."
        }

        $addonAsset = [string]$addon.asset
        $addonExpectedHash = ([string]$addon.sha256).ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($addonAsset) -or [string]::IsNullOrWhiteSpace($addonExpectedHash)) {
            throw "Addon '$addonName' has an invalid manifest entry."
        }

        $safeName = $addonName -replace '[^a-zA-Z0-9._-]', '_'
        $addonArchive = Join-Path $TempDir ("addon-$safeName.zip")
        $addonUri = "https://github.com/$Repo/releases/latest/download/$addonAsset"

        Write-Step "Downloading addon: $addonName"
        Download-File -Uri $addonUri -OutFile $addonArchive -Label "Downloading addon: $addonName" -ShowProgress

        Write-Step "Verifying addon SHA256: $addonName"
        $addonActualHash = (Get-FileHash -LiteralPath $addonArchive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($addonActualHash -ne $addonExpectedHash) {
            throw "Addon '$addonName' SHA256 mismatch. Expected $addonExpectedHash, got $addonActualHash"
        }

        Write-Step "Merging addon into profile: $addonName"
        Expand-Archive -LiteralPath $addonArchive -DestinationPath $staging -Force
    }

    $preloader = Join-Path $staging 'BepInEx\core\BepInEx.Preloader.dll'
    if (-not (Test-Path -LiteralPath $preloader)) {
        throw 'Downloaded profile does not contain BepInEx/core/BepInEx.Preloader.dll'
    }

    if (-not (Test-Path -LiteralPath (Join-Path $staging 'winhttp.dll'))) {
        throw 'Downloaded profile does not contain winhttp.dll'
    }

    Write-Step 'Switching profile'
    if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }

    $oldMoved = $false
    try {
        if (Test-Path -LiteralPath $profileDir) {
            Move-Item -LiteralPath $profileDir -Destination $backup
            $oldMoved = $true
        }
        Move-Item -LiteralPath $staging -Destination $profileDir
    }
    catch {
        if ($oldMoved -and -not (Test-Path -LiteralPath $profileDir) -and (Test-Path -LiteralPath $backup)) {
            Move-Item -LiteralPath $backup -Destination $profileDir
        }
        throw
    }

    Save-LocalState -Version ([string]$Manifest.version) -ProfileSha256 $expectedHash -Addons $Addons
    Write-Host "Installed modpack $($Manifest.version)" -ForegroundColor Green
}

function Prepare-WindowsDoorstop([object]$Config) {
    $profileDir = [string]$Config.profileDir
    $gameDir = [string]$Config.gameDir

    foreach ($name in @('winhttp.dll', '.doorstop_version')) {
        $source = Join-Path $profileDir $name
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Missing BepInEx bootstrap file in profile: $source"
        }
        Copy-Item -LiteralPath $source -Destination (Join-Path $gameDir $name) -Force
    }

    $sourceConfig = Join-Path $profileDir 'doorstop_config.ini'
    if (-not (Test-Path -LiteralPath $sourceConfig)) {
        throw "Missing doorstop_config.ini: $sourceConfig"
    }

    # Keep vanilla Steam launches vanilla. Our launcher enables Doorstop explicitly via CLI.
    $text = Get-Content -LiteralPath $sourceConfig -Raw
    $text = $text -replace '(?im)^\s*enabled\s*=\s*(true|false|1|0)\s*$', 'enabled = false'
    [System.IO.File]::WriteAllText((Join-Path $gameDir 'doorstop_config.ini'), $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Start-ModdedValheim([object]$Config) {
    Prepare-WindowsDoorstop $Config

    $profileDir = [string]$Config.profileDir
    $steamExe = Join-Path ([string]$Config.steamRoot) 'steam.exe'
    if (-not (Test-Path -LiteralPath $steamExe)) {
        throw "steam.exe not found: $steamExe"
    }

    $target = Join-Path $profileDir 'BepInEx\core\BepInEx.Preloader.dll'
    $doorstopVersionFile = Join-Path $profileDir '.doorstop_version'
    $doorstopVersion = if (Test-Path -LiteralPath $doorstopVersionFile) { (Get-Content -LiteralPath $doorstopVersionFile -Raw).Trim() } else { '4' }

    Write-Step 'Starting Valheim through Steam with the external BepInEx profile'

    if ($doorstopVersion -match '^4') {
        & $steamExe -applaunch $SteamAppId --doorstop-enabled true --doorstop-target-assembly $target --r2profile Druzhbodom
    }
    else {
        $args = @('-applaunch', $SteamAppId, '--doorstop-enable', 'true', '--doorstop-target', $target, '--r2profile', 'Druzhbodom')
        $corlib = Join-Path $profileDir 'unstripped_corlib'
        if (Test-Path -LiteralPath $corlib) {
            $args += @('--doorstop-dll-search-override', $corlib)
        }
        & $steamExe @args
    }
}

Invoke-SelfUpdate

$config = Get-LauncherConfig
if ($EnableLowSpec) {
    Set-LowSpecPreference -Config $config -Enabled $true
}
elseif ($DisableLowSpec) {
    Set-LowSpecPreference -Config $config -Enabled $false
}

$desiredAddons = @(Get-ConfiguredAddons $config)
Write-Host ("Selected addons: {0}" -f $(if ($desiredAddons.Count -gt 0) { $desiredAddons -join ', ' } else { '<none>' })) -ForegroundColor DarkGray

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("druzhbodom-update-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    Write-Step 'Checking latest GitHub Release'
    $manifest = Get-RemoteManifest -Repo $GitHubRepo -TempDir $tempDir
    $localState = Get-LocalState
    $localVersion = if ($localState) { [string]$localState.version } else { $null }
    $installedAddons = @(Get-StateAddons $localState)
    $addonsChanged = -not (Test-SameAddons -Left $installedAddons -Right $desiredAddons)
    $profileHealthy = Test-Path -LiteralPath (Join-Path ([string]$config.profileDir) 'BepInEx\core\BepInEx.Preloader.dll')

    if ($ForceUpdate -or -not $profileHealthy -or $localVersion -ne [string]$manifest.version -or $addonsChanged) {
        Write-Host "Local:  $localVersion"
        Write-Host "Remote: $($manifest.version)"
        if ($addonsChanged) {
            Write-Host ("Addon selection changed: installed=[{0}], desired=[{1}]" -f ($installedAddons -join ', '), ($desiredAddons -join ', ')) -ForegroundColor Yellow
        }
        Install-Profile -Manifest $manifest -Config $config -TempDir $tempDir -Repo $GitHubRepo -Addons $desiredAddons
    }
    else {
        Write-Host "Modpack $localVersion is up to date." -ForegroundColor Green
    }

    if (-not $NoLaunch) {
        Start-ModdedValheim $config
    }
}
finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
