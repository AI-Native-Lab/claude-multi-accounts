# Builds Claude Multi-Accounts for Windows into windows\dist:
#   ClaudeMultiAccounts.exe                     one file, .NET included, Windows 10/11 x64
#   ClaudeMultiAccounts-<version>-windows-x64.zip
# Runs the core tests first. Needs the .NET 8 SDK.
$ErrorActionPreference = 'Stop'
$windows = Split-Path -Parent $PSScriptRoot
$project = Join-Path $windows 'ClaudeMultiAccounts\ClaudeMultiAccounts.csproj'
$dist = Join-Path $windows 'dist'

dotnet run --project (Join-Path $windows 'CoreTests') -c Release
if ($LASTEXITCODE -ne 0) { throw 'Core tests failed.' }

Remove-Item -Recurse -Force $dist -ErrorAction SilentlyContinue
dotnet publish $project -c Release -r win-x64 --self-contained true -o $dist `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true `
    -p:DebugType=none -p:GenerateDocumentationFile=false
if ($LASTEXITCODE -ne 0) { throw 'Publish failed.' }

$version = ([xml](Get-Content $project)).Project.PropertyGroup.Version | Select-Object -First 1
$zip = Join-Path $dist "ClaudeMultiAccounts-$version-windows-x64.zip"
Compress-Archive -Path (Join-Path $dist 'ClaudeMultiAccounts.exe') -DestinationPath $zip -Force
Get-ChildItem $dist | Select-Object Name, @{ n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } }
