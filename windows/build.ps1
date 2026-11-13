# Builds "AI Sound Design Installer.exe" and the ZIP to attach to a GitHub release:
#
#   powershell -ExecutionPolicy Bypass -File windows\build.ps1 [version]   # default: the VERSION file
#
# A release does this on GitHub (.github/workflows/release.yml): push a tag v<version>
# and the ZIP is attached to the release; no Windows PC needed for that.
# Locally it needs the .NET SDK (any recent one; winget install Microsoft.DotNet.SDK.8);
# the app itself targets .NET Framework 4.8, which Windows 10 and 11 already have.
# The result, in windows\build\:
#   AI Sound Design Installer\            the .exe with install-components.ps1 beside it
#   AI-Sound-Design-Installer-Windows.zip (what users download)
#
# The app is not signed: the first time, Windows SmartScreen says it protected the PC;
# "More info" > "Run anyway".
# The app needs no new release when the services, the web UI or the plugin change: it
# fetches them from GitHub. A release is due when the app or install-components.ps1
# change; installed copies then offer to update themselves.
param([string]$Version = "")

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Version) { $Version = (Get-Content (Join-Path $here "..\VERSION") -Raw).Trim() }
$Version = $Version.TrimStart("v")
$out = Join-Path $here "build"
$name = "AI Sound Design Installer"
New-Item -ItemType Directory -Force -Path $out | Out-Null

Write-Host "== icon"
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here "make-icon.ps1") (Join-Path $out "icon.ico")

Write-Host "== compiling (version $Version)"
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw "The .NET SDK is missing: winget install Microsoft.DotNet.SDK.8" }
& dotnet build (Join-Path $here "Installer.csproj") -c Release -nologo -v quiet "-p:InstallerVersion=$Version"
if ($LASTEXITCODE -ne 0) { throw "the build failed" }

Write-Host "== app folder"
$app = Join-Path $out $name
if (Test-Path $app) { Remove-Item -Recurse -Force $app }
New-Item -ItemType Directory -Path $app | Out-Null
Copy-Item (Join-Path $out "bin\$name.exe") $app
Copy-Item (Join-Path $here "install-components.ps1") $app
Set-Content -Path (Join-Path $app "README.txt") -Encoding UTF8 -Value @"
AI Sound Design Installer $Version

Keep the two files together and double-click "$name.exe".
The first time, Windows SmartScreen may say it protected the PC: "More info" > "Run anyway".
Windows 10 or 11 (64-bit), an NVIDIA GPU; Docker Desktop if the backend is to run in containers.

https://github.com/ai-sound-design/installer
"@

Write-Host "== zip"
$zip = Join-Path $out "AI-Sound-Design-Installer-Windows.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path $app -DestinationPath $zip
Write-Host $app
Write-Host $zip
