#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$GaleBepInExPath = (Join-Path $env:APPDATA 'com.kesomannen.gale\valheim\profiles\Valheim Ochen Nado\BepInEx'),
    [string]$LowSpecGaleBepInExPath = $null,
    [string]$FtpHost = '185.189.255.48',
    [int]$FtpPort = 21,
    [string]$FtpRemoteArchive = '/Server/BepInEx/BepInEx.zip',
    [string]$GitHubRepo = 'idontknowhowbut/valheim-modpack-druzhbodom',
    [string]$Version = (Get-Date -Format 'yyyy.MM.dd.HHmmss'),
    [System.Management.Automation.PSCredential]$FtpCredential,
    [string]$GitHubToken = $env:GITHUB_TOKEN,
    [switch]$SkipFtp,
    [switch]$SkipGitHub,
    [switch]$SkipServerConfirmation,
    [switch]$NoFinalPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Optional local secrets file. It is intentionally excluded from Git by the
# repository .gitignore. Command-line parameters / GITHUB_TOKEN take priority.
$LocalSecretsPath = Join-Path $PSScriptRoot 'publish.local.ps1'
$LocalSecrets = $null

if (Test-Path -LiteralPath $LocalSecretsPath -PathType Leaf) {
    $LocalSecrets = & $LocalSecretsPath
    if (-not ($LocalSecrets -is [System.Collections.IDictionary])) {
        throw "publish.local.ps1 must return a hashtable with FtpUser, FtpPassword and GitHubToken values."
    }
}

function Get-LocalSecret([string]$Name) {
    if (-not $LocalSecrets) {
        return $null
    }

    if (-not $LocalSecrets.Contains($Name)) {
        return $null
    }

    $value = [string]$LocalSecrets[$Name]
    if ([string]::IsNullOrWhiteSpace($value) -or $value -eq 'CHANGE_ME') {
        return $null
    }

    return $value
}

function Write-Step([string]$Text) {
    Write-Host "`n==> $Text" -ForegroundColor Cyan
}

function Remove-IfExists([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Copy-DirectoryContents([string]$Source, [string]$Destination) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}

function Remove-RuntimeFiles([string]$Root) {
    # Per-player/runtime data should never be distributed as part of the canonical pack.
    Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -like '*_player_*.dat' -or
            $_.Name -eq 'LogOutput.log' -or
            $_.Name -eq 'LogOutput.txt'
        } |
        Remove-Item -Force

    $runtimeDirs = @(
        (Join-Path $Root 'BepInEx\cache')
    )
    foreach ($dir in $runtimeDirs) {
        Remove-IfExists $dir
    }
}

function New-Zip([string]$SourceDirectory, [string]$DestinationZip) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Remove-IfExists $DestinationZip
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $SourceDirectory,
        $DestinationZip,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-FtpCredentialFromLocalSecrets {
    $user = Get-LocalSecret 'FtpUser'
    $password = Get-LocalSecret 'FtpPassword'

    if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($password)) {
        return $null
    }

    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
    return New-Object System.Management.Automation.PSCredential($user, $securePassword)
}

function Get-PlainTextPassword([System.Management.Automation.PSCredential]$Credential) {
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Upload-FtpFile(
    [string]$LocalPath,
    [string]$HostName,
    [int]$Port,
    [string]$RemotePath,
    [System.Management.Automation.PSCredential]$Credential
) {
    $remote = $RemotePath.Replace('\\', '/').TrimStart('/')
    $uri = [Uri]("ftp://{0}:{1}/{2}" -f $HostName, $Port, $remote)

    $request = [System.Net.FtpWebRequest]::Create($uri)
    $request.Method = [System.Net.WebRequestMethods+Ftp]::UploadFile
    $request.UseBinary = $true
    $request.UsePassive = $true
    $request.KeepAlive = $false
    $request.Credentials = New-Object System.Net.NetworkCredential(
        $Credential.UserName,
        (Get-PlainTextPassword $Credential)
    )

    $fileInfo = Get-Item -LiteralPath $LocalPath
    $request.ContentLength = $fileInfo.Length

    $input = [System.IO.File]::OpenRead($LocalPath)
    try {
        $output = $request.GetRequestStream()
        try {
            $input.CopyTo($output)
        }
        finally {
            $output.Dispose()
        }
    }
    finally {
        $input.Dispose()
    }

    $response = $request.GetResponse()
    try {
        Write-Host ("FTP: {0}" -f $response.StatusDescription.Trim())
    }
    finally {
        $response.Dispose()
    }
}

function Get-GitHubHeaders([string]$Token) {
    return @{
        Authorization          = "Bearer $Token"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'valheim-modpack-druzhbodom-publisher'
    }
}

function Get-GitHubTargetBranch([string]$Repo, [string]$Token) {
    $headers = Get-GitHubHeaders $Token

    $repoInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo" -Method Get -Headers $headers
    $branch = [string]$repoInfo.default_branch
    if ([string]::IsNullOrWhiteSpace($branch)) {
        $branch = 'main'
    }

    # A Release tag must ultimately point at a commit. An absolutely empty repository
    # has no commit to target, so detect that before touching the game-server FTP.
    try {
        Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/commits/$branch" -Method Get -Headers $headers | Out-Null
    }
    catch {
        throw "GitHub repository '$Repo' does not have a commit on '$branch'. Create an initial commit (for example README.md) and run publish.ps1 again."
    }

    return $branch
}

function New-GitHubDraftRelease(
    [string]$Repo,
    [string]$Token,
    [string]$ReleaseVersion,
    [string]$TargetBranch
) {
    $headers = Get-GitHubHeaders $Token
    $tag = "v$ReleaseVersion"
    $body = @{
        tag_name         = $tag
        target_commitish = $TargetBranch
        name             = "Druzhbodom $tag"
        body             = "Automated Valheim modpack release $tag"
        draft            = $true
        prerelease       = $false
    } | ConvertTo-Json

    $params = @{
        Uri = "https://api.github.com/repos/$Repo/releases"
        Method = 'Post'
        Headers = $headers
        ContentType = 'application/json'
        Body = $body
    }
    return Invoke-RestMethod @params
}

function Upload-GitHubReleaseAsset([string]$Repo, [string]$Token, [long]$ReleaseId, [string]$Path) {
    $headers = Get-GitHubHeaders $Token
    $file = Get-Item -LiteralPath $Path
    $name = [Uri]::EscapeDataString($file.Name)
    $uri = "https://uploads.github.com/repos/$Repo/releases/$ReleaseId/assets?name=$name"
    $sizeMiB = [Math]::Round($file.Length / 1MB, 2)

    Write-Host ("Uploading {0} ({1} MiB) to GitHub..." -f $file.Name, $sizeMiB) -ForegroundColor Cyan

    $params = @{
        Uri = $uri
        Method = 'Post'
        Headers = $headers
        ContentType = 'application/octet-stream'
        InFile = $Path
        UseBasicParsing = $true
    }
    Invoke-WebRequest @params | Out-Null

    Write-Host ("Uploaded {0}." -f $file.Name) -ForegroundColor Green
}

function Publish-GitHubRelease([string]$Repo, [string]$Token, [long]$ReleaseId) {
    $headers = Get-GitHubHeaders $Token
    $body = @{ draft = $false } | ConvertTo-Json

    $params = @{
        Uri = "https://api.github.com/repos/$Repo/releases/$ReleaseId"
        Method = 'Patch'
        Headers = $headers
        ContentType = 'application/json'
        Body = $body
    }
    Invoke-RestMethod @params | Out-Null
}

# --- GitHub preflight ---------------------------------------------------------

$GitHubTargetBranch = $null
if (-not $SkipGitHub) {
    if ([string]::IsNullOrWhiteSpace($GitHubToken)) {
        $GitHubToken = Get-LocalSecret 'GitHubToken'
    }
    if ([string]::IsNullOrWhiteSpace($GitHubToken)) {
        $secureToken = Read-Host 'GitHub token (fine-grained PAT with Contents: Read and write)' -AsSecureString
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
        try {
            $GitHubToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        }
    }

    Write-Step 'Checking GitHub repository'
    $GitHubTargetBranch = Get-GitHubTargetBranch -Repo $GitHubRepo -Token $GitHubToken
    Write-Host "GitHub target branch: $GitHubTargetBranch" -ForegroundColor Green
}

# --- Validate source profiles ------------------------------------------------

# Optional client-only addon. Keep its path in publish.local.ps1 or pass
# -LowSpecGaleBepInExPath explicitly. If no path is configured, the release is
# published without the addon.
if ([string]::IsNullOrWhiteSpace($LowSpecGaleBepInExPath)) {
    $LowSpecGaleBepInExPath = Get-LocalSecret 'LowSpecGaleBepInExPath'
}
$PublishLowSpecAddon = -not [string]::IsNullOrWhiteSpace($LowSpecGaleBepInExPath)

if (-not (Test-Path -LiteralPath $GaleBepInExPath -PathType Container)) {
    throw "Gale BepInEx directory not found: $GaleBepInExPath"
}

$profileRoot = Split-Path -Parent $GaleBepInExPath
$required = @(
    (Join-Path $GaleBepInExPath 'core\BepInEx.Preloader.dll'),
    (Join-Path $GaleBepInExPath 'plugins'),
    (Join-Path $GaleBepInExPath 'config'),
    (Join-Path $profileRoot 'winhttp.dll'),
    (Join-Path $profileRoot 'doorstop_config.ini'),
    (Join-Path $profileRoot '.doorstop_version')
)

foreach ($path in $required) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required profile component not found: $path"
    }
}

$linuxLauncher = @(
    (Join-Path $profileRoot 'start_game_bepinex.sh'),
    (Join-Path $profileRoot 'run_bepinex.sh')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if (-not $linuxLauncher) {
    Write-Warning 'No start_game_bepinex.sh/run_bepinex.sh found in Gale profile. Windows will work, Linux client launch will not.'
}

if ($PublishLowSpecAddon) {
    if (-not (Test-Path -LiteralPath $LowSpecGaleBepInExPath -PathType Container)) {
        throw "Low-spec Gale BepInEx directory not found: $LowSpecGaleBepInExPath"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $LowSpecGaleBepInExPath 'plugins') -PathType Container)) {
        throw "Low-spec Gale profile has no plugins directory: $LowSpecGaleBepInExPath"
    }
    Write-Host "Low-spec addon source: $LowSpecGaleBepInExPath" -ForegroundColor Green
}
else {
    Write-Host 'Low-spec addon: not configured, skipping.' -ForegroundColor DarkGray
}

# --- Build archives -----------------------------------------------------------

$workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("valheim-modpack-publish-" + [Guid]::NewGuid().ToString('N'))
$serverStage = Join-Path $workRoot 'server'
$clientStage = Join-Path $workRoot 'client'
$lowSpecStage = Join-Path $workRoot 'addon-low-spec'
$outDir = Join-Path $workRoot 'out'
New-Item -ItemType Directory -Path $serverStage, $clientStage, $lowSpecStage, $outDir -Force | Out-Null

try {
    Write-Step 'Building server BepInEx.zip'
    foreach ($folder in @('config', 'plugins')) {
        $source = Join-Path $GaleBepInExPath $folder
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination $serverStage -Recurse -Force
        }
    }
    Remove-RuntimeFiles $serverStage

    $serverZip = Join-Path $outDir 'BepInEx.zip'
    New-Zip $serverStage $serverZip

    Write-Step 'Building full client profile (includes BepInEx bootstrap/runtime)'
    Copy-DirectoryContents $profileRoot $clientStage
    Remove-RuntimeFiles $clientStage

    $clientZip = Join-Path $outDir 'client-profile.zip'
    New-Zip $clientStage $clientZip

    $clientHash = Get-Sha256 $clientZip
    $serverHash = Get-Sha256 $serverZip

    $lowSpecZip = $null
    $lowSpecHash = $null
    if ($PublishLowSpecAddon) {
        Write-Step 'Building client-only low-spec addon'
        $addonBepInEx = Join-Path $lowSpecStage 'BepInEx'
        New-Item -ItemType Directory -Path $addonBepInEx -Force | Out-Null

        foreach ($folder in @('config', 'plugins')) {
            $source = Join-Path $LowSpecGaleBepInExPath $folder
            if (Test-Path -LiteralPath $source -PathType Container) {
                Copy-Item -LiteralPath $source -Destination $addonBepInEx -Recurse -Force
            }
        }
        Remove-RuntimeFiles $lowSpecStage

        $lowSpecZip = Join-Path $outDir 'addon-low-spec.zip'
        New-Zip $lowSpecStage $lowSpecZip
        $lowSpecHash = Get-Sha256 $lowSpecZip
    }

    $addons = [ordered]@{}
    if ($lowSpecZip) {
        $addons['low-spec'] = [ordered]@{
            name   = 'Low-spec optimization'
            asset  = 'addon-low-spec.zip'
            sha256 = $lowSpecHash
            size   = (Get-Item -LiteralPath $lowSpecZip).Length
        }
    }

    $manifest = [ordered]@{
        schema            = 2
        version           = $Version
        steamAppId        = 892970
        profileAsset      = 'client-profile.zip'
        profileSha256     = $clientHash
        profileSize       = (Get-Item -LiteralPath $clientZip).Length
        serverArchive     = 'BepInEx.zip'
        serverSha256      = $serverHash
        addons            = $addons
        createdAtUtc      = (Get-Date).ToUniversalTime().ToString('o')
        sourceDescription = 'Gale profile root; runtime files removed; optional client addons are layered over the base profile'
    }
    $manifestPath = Join-Path $outDir 'manifest.json'
    [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))

    Write-Host "Server archive: $serverZip"
    Write-Host "Client archive: $clientZip"
    Write-Host "Client SHA256:  $clientHash"
    if ($lowSpecZip) {
        Write-Host "Low-spec addon: $lowSpecZip"
        Write-Host "Low-spec SHA256: $lowSpecHash"
    }

    # --- FTP first ------------------------------------------------------------
    if (-not $SkipFtp) {
        Write-Step 'Uploading BepInEx.zip to game-server FTP'
        if (-not $FtpCredential) {
            $FtpCredential = New-FtpCredentialFromLocalSecrets
        }
        if (-not $FtpCredential) {
            $FtpCredential = Get-Credential -Message "FTP credentials for $FtpHost"
        }
        Upload-FtpFile -LocalPath $serverZip -HostName $FtpHost -Port $FtpPort -RemotePath $FtpRemoteArchive -Credential $FtpCredential

        if (-not $SkipServerConfirmation) {
            Write-Host ''
            Write-Host 'FTP upload completed.' -ForegroundColor Green
            Write-Host 'Now open the hosting panel, click the BepInEx.zip unpack button, and restart/verify the server.' -ForegroundColor Yellow
            Read-Host 'When the server is ready, press Enter to publish the client release on GitHub' | Out-Null
        }
    }

    # --- GitHub release second ------------------------------------------------
    if (-not $SkipGitHub) {
        Write-Step 'Publishing GitHub Release for clients'

        $release = New-GitHubDraftRelease -Repo $GitHubRepo -Token $GitHubToken -ReleaseVersion $Version -TargetBranch $GitHubTargetBranch
        Write-Host "Draft release created: $($release.html_url)"

        try {
            Upload-GitHubReleaseAsset -Repo $GitHubRepo -Token $GitHubToken -ReleaseId $release.id -Path $clientZip
            if ($lowSpecZip) {
                Upload-GitHubReleaseAsset -Repo $GitHubRepo -Token $GitHubToken -ReleaseId $release.id -Path $lowSpecZip
            }
            Upload-GitHubReleaseAsset -Repo $GitHubRepo -Token $GitHubToken -ReleaseId $release.id -Path $manifestPath
            Write-Host 'Publishing release...' -ForegroundColor Cyan
            Publish-GitHubRelease -Repo $GitHubRepo -Token $GitHubToken -ReleaseId $release.id
        }
        catch {
            Write-Warning "GitHub upload failed. The release was intentionally left as a DRAFT: $($release.html_url)"
            throw
        }

        Write-Host ''
        Write-Host "Published v$Version" -ForegroundColor Green
        Write-Host "https://github.com/$GitHubRepo/releases/latest"
    }

    Write-Host ''
    Write-Host 'Загрузка успешна.' -ForegroundColor Green
    if (-not $NoFinalPause) {
        Read-Host 'Нажмите Enter для выхода' | Out-Null
    }
}
finally {
    Remove-IfExists $workRoot
}
