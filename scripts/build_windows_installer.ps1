param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$dotnet = Get-Command dotnet -ErrorAction Stop
$iscc = @(
    $env:INNO_SETUP_COMPILER,
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $iscc) { throw "Install Inno Setup 6, or set INNO_SETUP_COMPILER to ISCC.exe." }

if (-not $env:STG_GOOGLE_CLIENT_SECRET -and (Test-Path "$root\android\local.properties")) {
    $entry = Get-Content "$root\android\local.properties" | Where-Object { $_ -match '^STG_GOOGLE_CLIENT_SECRET=' } | Select-Object -First 1
    if ($entry) { $env:STG_GOOGLE_CLIENT_SECRET = $entry.Substring($entry.IndexOf('=') + 1) }
}
if (-not $env:STG_GOOGLE_CLIENT_SECRET) { throw "Set STG_GOOGLE_CLIENT_SECRET or add it to Git-ignored android\local.properties." }

$env:NUGET_PACKAGES = "$root\.build\nuget"
& $dotnet.Source publish "$root\windows\ScreenTimeGuardian\ScreenTimeGuardian.csproj" -c $Configuration -r win-x64 --self-contained true -p:EnableWindowsTargeting=true -p:UseSharedCompilation=false --disable-build-servers -o "$root\dist\windows"
if ($LASTEXITCODE -ne 0) { throw "Windows publish failed." }

& $iscc "/DSourceDir=$root\dist\windows" "/DOutputDir=$root\dist" "$root\windows\installer\ScreenTimeGuardian.iss"
if ($LASTEXITCODE -ne 0) { throw "Inno Setup packaging failed." }
