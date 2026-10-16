#requires -Version 7.0
param([switch]$SkipBuild, [string]$ReleaseDirectory)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $SkipBuild) {
    Push-Location $projectRoot
    try {
        & flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw 'Windows release build failed.' }
    } finally { Pop-Location }
}
$releasePath = if ($ReleaseDirectory) { $ReleaseDirectory } else { Join-Path $projectRoot 'build/windows/x64/runner/Release' }
$releaseRoot = (Resolve-Path -LiteralPath $releasePath).Path
if (-not (Test-Path -LiteralPath (Join-Path $releaseRoot 'we_workshop_monitor.exe'))) {
    throw 'The release executable is missing.'
}
$version = [regex]::Match((Get-Content -LiteralPath (Join-Path $projectRoot 'pubspec.yaml') -Raw), 'version:\s*(\d+\.\d+\.\d+)').Groups[1].Value
if (-not $version) { throw 'Missing application version.' }
$distRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot 'dist'))
New-Item -ItemType Directory -Path $distRoot -Force | Out-Null
$zipPath = [IO.Path]::GetFullPath((Join-Path $distRoot "WE_Workshop_Monitor_${version}_windows_x64.zip"))
if (-not $zipPath.StartsWith($distRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to write an archive outside dist.'
}

# Flutter's application-local deployment requires the x64 MSVC redistributables.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vsInstall = & $vswhere -latest -property installationPath
$redistRoot = Join-Path $vsInstall 'VC/Redist/MSVC'
$crtRoot = $null
foreach ($directory in (Get-ChildItem -LiteralPath $redistRoot -Directory | Sort-Object Name -Descending)) {
    $x64 = Join-Path $directory.FullName 'x64'
    if (Test-Path -LiteralPath $x64) {
        $crtRoot = Get-ChildItem -LiteralPath $x64 -Directory -Filter 'Microsoft.VC*.CRT' | Select-Object -First 1
        if ($crtRoot) { break }
    }
}
if (-not $crtRoot) { throw 'The Visual C++ x64 redistributable directory is missing.' }
foreach ($required in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $crtRoot.FullName $required))) { throw "Missing $required" }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
if (Test-Path -LiteralPath $zipPath) { [IO.File]::Delete($zipPath) }
$archive = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
$names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
try {
    foreach ($file in (Get-ChildItem -LiteralPath $releaseRoot -Recurse -File)) {
        if ($file.Extension -in @('.pdb', '.ilk', '.exp', '.lib')) { continue }
        $relative = [IO.Path]::GetRelativePath($releaseRoot, $file.FullName).Replace('\', '/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $relative, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        $names.Add($relative) | Out-Null
    }
    foreach ($file in (Get-ChildItem -LiteralPath $crtRoot.FullName -Filter '*.dll' -File)) {
        if ($names.Add($file.Name)) {
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $file.Name, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    }
    $entry = $archive.CreateEntry('START_HERE.txt')
    $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
    try {
        $writer.WriteLine("WE Workshop Monitor $version - Windows x64")
        $writer.WriteLine('Extract the entire ZIP into a folder, then run we_workshop_monitor.exe.')
        $writer.WriteLine('Keep the data folder and all DLL files beside the executable.')
        $writer.WriteLine('This package contains the app only, not your archives, passwords or API keys.')
        $writer.WriteLine('Existing user archives remain in the Windows application-data directory.')
    } finally { $writer.Dispose() }
} finally { $archive.Dispose() }
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$zipPath.sha256", "$hash  $([IO.Path]::GetFileName($zipPath))`n", [Text.UTF8Encoding]::new($false))
Write-Output $zipPath
Write-Output "SHA256: $hash"
