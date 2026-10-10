param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root "windows\ScreenTimeGuardian.Package\ScreenTimeGuardian.Package.wapproj"

if (-not (Get-Command msbuild -ErrorAction SilentlyContinue)) {
    throw "Install Visual Studio 2022 with the .NET desktop development and Windows application development workloads."
}

# Package.appxmanifest must first be associated with the reserved Partner Center product.
msbuild $project /restore "/p:Configuration=$Configuration" /p:Platform=x64 /p:UapAppxPackageBuildMode=StoreUpload /p:AppxBundle=Always /p:AppxBundlePlatforms="x64|ARM64"

Write-Host "Store upload package created under windows\ScreenTimeGuardian.Package\AppPackages. Upload the .msixupload file in Partner Center."
