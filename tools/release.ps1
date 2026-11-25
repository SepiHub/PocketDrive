<#
.SYNOPSIS
  Builds a PocketDrive release: the Windows installer and the Android APK.

.DESCRIPTION
  Without -Publish it only builds, into the dist folder, so you can test.
  With -Publish it also tags the commit and uploads both files as a GitHub
  release. Installed copies of PocketDrive (PC and phone) find it there and
  offer the update.

.EXAMPLE
  .\tools\release.ps1                  # next patch version, build only
  .\tools\release.ps1 -Version 1.2.0   # a specific version
  .\tools\release.ps1 -Publish         # build and publish on GitHub
#>
param(
  [string]$Version,
  [switch]$Publish,
  [string]$Notes
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Run($exe) {
  & $exe @args
  if ($LASTEXITCODE -ne 0) { throw "$exe failed (exit code $LASTEXITCODE)" }
}

# --- Version --------------------------------------------------------------
Push-Location $root
try {
  if (-not $Version) {
    $last = git tag --list 'v*' --sort=-v:refname | Select-Object -First 1
    if ($last -match '^v(\d+)\.(\d+)\.(\d+)$') {
      $Version = '{0}.{1}.{2}' -f $Matches[1], $Matches[2], ([int]$Matches[3] + 1)
    } else {
      $Version = '1.0.0'
    }
  }
  if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)$') { throw "Version must look like 1.2.3" }
  $buildNumber = [int]$Matches[1] * 10000 + [int]$Matches[2] * 100 + [int]$Matches[3]
  $tag = "v$Version"
  if (git tag --list $tag) { throw "$tag already exists. Pick a higher version." }

  if ($Publish -and (git status --porcelain)) {
    throw 'You have uncommitted changes. Commit them first, so the release matches GitHub.'
  }

  # --- Tools --------------------------------------------------------------
  $iscc = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $iscc) {
    throw 'Inno Setup 6 is not installed. Install it with: winget install JRSoftware.InnoSetup'
  }
  if (-not (Test-Path (Join-Path $root 'phone_app\android\key.properties'))) {
    throw 'The Android signing key is missing (phone_app\android\key.properties).'
  }

  Write-Host "Building PocketDrive $Version (build $buildNumber)" -ForegroundColor Green
  New-Item -ItemType Directory -Force $dist | Out-Null
  $common = @("--build-name=$Version", "--build-number=$buildNumber", "--dart-define=PD_VERSION=$Version")

  # --- Windows ------------------------------------------------------------
  Step 'Windows app'
  Push-Location (Join-Path $root 'pc_app')
  try { Run flutter build windows --release @common } finally { Pop-Location }

  Step 'Windows installer'
  Run $iscc /Q "/DAppVersion=$Version" (Join-Path $root 'installer\pocketdrive.iss')
  $setup = Join-Path $dist "PocketDrive-Setup-$Version.exe"

  # --- Android ------------------------------------------------------------
  Step 'Android app'
  Push-Location (Join-Path $root 'phone_app')
  try { Run flutter build apk --release --target-platform android-arm64 @common } finally { Pop-Location }
  $apk = Join-Path $dist "PocketDrive-$Version.apk"
  Copy-Item (Join-Path $root 'phone_app\build\app\outputs\flutter-apk\app-release.apk') $apk -Force

  Step 'Done'
  Get-Item $setup, $apk | ForEach-Object {
    '{0}  ({1:N1} MB)' -f $_.FullName, ($_.Length / 1MB)
  }

  # --- Publish ------------------------------------------------------------
  if ($Publish) {
    Step "Publishing $tag on GitHub"
    Run git tag -a $tag -m "PocketDrive $Version"
    Run git push origin $tag
    $noteArgs = if ($Notes) { @('--notes', $Notes) } else { @('--generate-notes') }
    Run gh release create $tag $setup $apk --title "PocketDrive $Version" @noteArgs
    Write-Host "`nPublished. Installed copies will offer the update." -ForegroundColor Green
  } else {
    Write-Host "`nNot published (add -Publish to put it on GitHub)." -ForegroundColor Yellow
  }
} finally {
  Pop-Location
}
