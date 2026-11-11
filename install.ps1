#Requires -Version 5.1
<#
.SYNOPSIS
    DSH Launcher を GitHub Releases からインストールします。

.DESCRIPTION
    自己完結（.NET ランタイム不要）の単一 exe をダウンロードし、SHA256 を検証して
    %LOCALAPPDATA%\Programs\DshLauncher に配置し、スタートメニューにショートカットを作ります。
    実行中の旧バージョン（同じ配置先のもの）は終了して置き換えます。

.PARAMETER Version
    インストールするバージョン（例: v0.1.10 / 0.1.10）。既定は latest。

.PARAMETER InstallDir
    配置先。既定は %LOCALAPPDATA%\Programs\DshLauncher。
    配置先にコピーされた install.ps1 から実行した場合は、そのフォルダ（dshl.exe と同じ場所）を既定にする。

.PARAMETER NoShortcut
    スタートメニューのショートカットを作らない。

.PARAMETER Launch
    インストール後に起動する。

.PARAMETER Uninstall
    アンインストールする（ショートカットとインストール先を削除）。

.PARAMETER Purge
    -Uninstall と併用。設定・ログ（%APPDATA%\DshLauncher）も削除する。

.EXAMPLE
    irm https://github.com/Aosy0/dsh-launcher/releases/latest/download/install.ps1 | iex

.EXAMPLE
    pwsh -File install.ps1 -Version v0.1.10

.EXAMPLE
    $env:LOCALAPPDATA\Programs\DshLauncher\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$Version = 'latest',
    [string]$InstallDir,
    [switch]$NoShortcut,
    [switch]$Launch,
    [switch]$Uninstall,
    [switch]$Purge
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw 'DSH Launcher は Windows でのみ動作します。'
}
if ($PSVersionTable.PSVersion.Major -lt 6) {
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        # TLS 1.2 is already the default on supported Windows versions.
    }
}

$Repo = 'Aosy0/dsh-launcher'
$AppName = 'DSH Launcher'
$ExeName = 'dshl.exe'
$ShortcutName = 'DSH Launcher.lnk'
$UserAgent = 'dshl-install-script'

$StartMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$StartMenuShortcut = Join-Path $StartMenu $ShortcutName
$DesktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) $ShortcutName
$ConfigDir = Join-Path $env:APPDATA 'DshLauncher'

# When this script is the copy installed next to dshl.exe, its own folder is the install dir.
$scriptRoot = ''
try { $scriptRoot = $PSScriptRoot } catch { }

# An installed copy of this script sits next to dshl.exe: default to that folder so
# `-Uninstall` (and reinstall) work without remembering a custom -InstallDir.
if (-not $PSBoundParameters.ContainsKey('InstallDir')) {
    if ($scriptRoot -and (Test-Path -LiteralPath (Join-Path $scriptRoot $ExeName))) {
        $InstallDir = $scriptRoot
    } else {
        $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\DshLauncher'
    }
}
$InstallExe = Join-Path $InstallDir $ExeName

function Test-ScriptInsideInstallDir {
    if (-not $scriptRoot) { return $false }
    try {
        return [string]::Equals(
            [System.IO.Path]::GetFullPath($scriptRoot).TrimEnd('\'),
            [System.IO.Path]::GetFullPath($InstallDir).TrimEnd('\'),
            [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Get-Release {
    $headers = @{ 'User-Agent' = $UserAgent; 'Accept' = 'application/vnd.github+json' }
    if ($Version -eq 'latest') {
        return Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $headers -TimeoutSec 60
    }
    $tag = if ($Version.StartsWith('v')) { $Version } else { "v$Version" }
    return Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/tags/$tag" -Headers $headers -TimeoutSec 60
}

function Save-Asset([object]$Asset, [string]$Path) {
    Write-Step ("ダウンロード {0} ({1:N1} MB)" -f $Asset.name, ($Asset.size / 1MB))
    Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $Path `
        -Headers @{ 'User-Agent' = $UserAgent } -TimeoutSec 600 | Out-Null
}

function Assert-Checksum([string]$FilePath, [string]$FileName, [object]$Release, [string]$TempDir) {
    $sumsAsset = $Release.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' } | Select-Object -First 1
    if (-not $sumsAsset) {
        Write-Warning 'SHA256SUMS.txt がリリースに無いため、チェックサム検証をスキップしました。'
        return
    }
    $sumsPath = Join-Path $TempDir 'SHA256SUMS.txt'
    Invoke-WebRequest -Uri $sumsAsset.browser_download_url -OutFile $sumsPath `
        -Headers @{ 'User-Agent' = $UserAgent } -TimeoutSec 120 | Out-Null

    $expected = $null
    foreach ($line in Get-Content -Path $sumsPath) {
        if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$' -and $matches[2] -eq $FileName) {
            $expected = $matches[1]
            break
        }
    }
    if (-not $expected) {
        throw "$FileName の SHA256 が SHA256SUMS.txt に見つかりません。"
    }
    $actual = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash
    if ($actual -ne $expected.ToUpperInvariant()) {
        throw "チェックサムが一致しません（ダウンロード破損または改ざんの可能性）: $FileName"
    }
    Write-Host '    チェックサム OK' -ForegroundColor DarkGray
}

function Stop-InstalledProcess {
    $running = @(Get-Process -Name dshl -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $InstallExe })
    foreach ($process in $running) {
        Write-Step "実行中の $AppName (PID $($process.Id)) を終了します"
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    if ($running.Count -gt 0) { Start-Sleep -Milliseconds 700 }
}

if ($Uninstall) {
    Write-Step "アンインストール: $AppName"
    Stop-InstalledProcess
    foreach ($shortcut in @($StartMenuShortcut, $DesktopShortcut)) {
        if (Test-Path -LiteralPath $shortcut) {
            Remove-Item -LiteralPath $shortcut -Force
            Write-Host "    削除: $shortcut"
        }
    }
    if (Test-Path -LiteralPath $InstallDir) {
        if (Test-ScriptInsideInstallDir) {
            # The running .cmd/.ps1 lives inside the folder: deleting it from here makes cmd.exe
            # complain while it still reads the batch file. Let a detached cmd remove it after we exit.
            $command = 'timeout /t 2 /nobreak >nul & rmdir /s /q "' + $InstallDir + '"'
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $env:ComSpec
            $startInfo.Arguments = '/c ' + $command
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
            [System.Diagnostics.Process]::Start($startInfo) | Out-Null
            Write-Host "    削除予約: $InstallDir（数秒後に削除）"
        } else {
            for ($attempt = 1; $attempt -le 5; $attempt++) {
                try {
                    Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop
                    break
                } catch {
                    if ($attempt -eq 5) { throw "削除できませんでした（実行中のプロセスが残っている可能性）: $InstallDir`n$($_.Exception.Message)" }
                    Start-Sleep -Milliseconds 500
                }
            }
            Write-Host "    削除: $InstallDir"
        }
    } else {
        Write-Host "    （配置先は見つかりませんでした: $InstallDir）"
    }
    if ($Purge -and (Test-Path -LiteralPath $ConfigDir)) {
        Remove-Item -LiteralPath $ConfigDir -Recurse -Force
        Write-Host "    削除: $ConfigDir（設定・ログ）"
    } elseif (Test-Path -LiteralPath $ConfigDir) {
        Write-Host "    設定は残しています: $ConfigDir（-Purge で削除）"
    }
    Write-Host 'アンインストールしました。' -ForegroundColor Green
    return
}

Write-Step "DSH Launcher のインストール（リポジトリ: $Repo）"
$release = Get-Release
$tag = $release.tag_name
$releaseVersion = $tag.TrimStart('v')
$assetName = "dshl-$releaseVersion-win-x64.exe"
$asset = $release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
if (-not $asset) {
    $available = ($release.assets | ForEach-Object { $_.name }) -join ', '
    throw "$assetName がリリース $tag に見つかりません（利用可能: $available）"
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('dshl-install-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
try {
    $download = Join-Path $tempDir $assetName
    Save-Asset -Asset $asset -Path $download
    Assert-Checksum -FilePath $download -FileName $assetName -Release $release -TempDir $tempDir

    Stop-InstalledProcess
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Write-Step "配置: $InstallExe"
    Copy-Item -LiteralPath $download -Destination $InstallExe -Force
    try { Unblock-File -Path $InstallExe -ErrorAction SilentlyContinue } catch { }

    if (-not $NoShortcut) {
        Write-Step 'スタートメニューのショートカットを作成'
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($StartMenuShortcut)
        $shortcut.TargetPath = $InstallExe
        $shortcut.WorkingDirectory = $InstallDir
        $shortcut.IconLocation = "$InstallExe,0"
        $shortcut.Description = $AppName
        $shortcut.Save()
    }

    # Keep the installer next to the exe so it can update or uninstall itself later.
    $scriptAsset = $release.assets | Where-Object { $_.name -eq 'install.ps1' } | Select-Object -First 1
    if ($scriptAsset) {
        try {
            $downloadedScript = Join-Path $tempDir 'install.ps1'
            Invoke-WebRequest -Uri $scriptAsset.browser_download_url -OutFile $downloadedScript `
                -Headers @{ 'User-Agent' = $UserAgent } -TimeoutSec 120 | Out-Null

            # Windows PowerShell 5.1 reads BOM-less UTF-8 as CP932 and breaks on the Japanese text,
            # so the installed copy is written as UTF-8 WITH BOM for update.cmd / uninstall.cmd.
            $scriptText = [System.IO.File]::ReadAllText($downloadedScript)
            [System.IO.File]::WriteAllText(
                (Join-Path $InstallDir 'install.ps1'),
                $scriptText,
                [System.Text.UTF8Encoding]::new($true))

            # .cmd shims: the default Windows PowerShell execution policy can block .ps1 files,
            # so updating/uninstalling from the installed folder goes through these instead.
            $updateCmd = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0install.ps1`" %*`r`n"
            $uninstallCmd = "@echo off`r`ncd /d `"%TEMP%`"`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0install.ps1`" -Uninstall %*`r`n"
            Set-Content -Path (Join-Path $InstallDir 'update.cmd') -Value $updateCmd -Encoding Ascii
            Set-Content -Path (Join-Path $InstallDir 'uninstall.cmd') -Value $uninstallCmd -Encoding Ascii
        } catch {
            Write-Warning "install.ps1 を配置できませんでした: $($_.Exception.Message)"
        }
    }
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

$installedVersion = ''
try { $installedVersion = ((& $InstallExe --version) | Out-String).Trim() } catch { }

$installerPath = Join-Path $InstallDir 'install.ps1'
$uninstallCmdPath = Join-Path $InstallDir 'uninstall.cmd'
$updateCmdPath = Join-Path $InstallDir 'update.cmd'
Write-Host ''
Write-Host "インストールしました: $InstallExe" -ForegroundColor Green
if ($installedVersion) { Write-Host "    バージョン: $installedVersion" }
if (-not $NoShortcut) { Write-Host "    スタートメニュー: $AppName" }
Write-Host "    起動: `"$InstallExe`""
if (Test-Path -LiteralPath $updateCmdPath) {
    Write-Host "    更新: `"$updateCmdPath`""
} elseif (Test-Path -LiteralPath $installerPath) {
    Write-Host "    更新: `"$installerPath`"  /  アンインストール: `"$installerPath`" -Uninstall"
}
if (Test-Path -LiteralPath $uninstallCmdPath) {
    Write-Host "    アンインストール: `"$uninstallCmdPath`"（設定も消す: `"$uninstallCmdPath`" -Purge）"
}
Write-Host '    設定: %APPDATA%\DshLauncher\hosts.json（初回起動時に作成）'

if ($Launch) {
    Write-Step '起動'
    Start-Process -FilePath $InstallExe | Out-Null
}
