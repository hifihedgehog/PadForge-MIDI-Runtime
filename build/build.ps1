<#
Builds the Windows MIDI Services App SDK runtime from microsoft/MIDI at tag
rc-4 and packages it as PadForge-MIDI-Runtime installers for x64 and ARM64.

    powershell -ExecutionPolicy Bypass -File build\build.ps1 -Workspace C:\mb-build

The workspace must be a new folder whose path has no spaces: MSBuild's
SolutionDir needs a trailing backslash, which a quoted path would escape.
Needs git, the .NET 10 SDK and Visual Studio 2026 with the components listed
in README.md. Output lands in <workspace>\out.

The steps follow Microsoft's own build (build\nuke_build\Build.cs and
build\nuke_build-service\Build.cs in the tag) for the parts the runtime needs.
#>
param(
    [Parameter(Mandatory = $true)][string]$Workspace,
    [string]$Tag = 'rc-4',
    [string]$Commit = 'd1d274a67102c28a94b6a96d262f7071d5ee7281',
    [int]$Major = 1,
    [int]$Minor = 0,
    [int]$Patch = 17,
    [int]$BuildNumber = 25,
    [string]$PreviewString = 'rc.4.25',
    [string]$VersionName = 'SDK Release Candidate 4',
    [string]$WindowsSdk = '10.0.26100.0'
)

$ErrorActionPreference = 'Stop'

if ($Workspace -match '\s') { throw "The workspace path must not contain spaces: $Workspace" }
if (Test-Path $Workspace) { throw "The workspace already exists. Pick a new folder: $Workspace" }

$repoRoot = Split-Path -Parent $PSScriptRoot
$semVersion = "$Major.$Minor.$Patch-$PreviewString"
$fileVersion = "$Major.$Minor.$Patch.$BuildNumber"

# --- Tools -------------------------------------------------------------------

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$components = @(
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
    'Microsoft.VisualStudio.Component.VC.Tools.ARM64',
    'Microsoft.VisualStudio.Component.VC.Tools.ARM64EC',
    'Microsoft.VisualStudio.Component.VC.14.44.17.14.x86.x64',
    'Microsoft.VisualStudio.Component.VC.14.44.17.14.ARM64',
    'Microsoft.VisualStudio.Component.VC.14.44.17.14.ATL',
    'Microsoft.VisualStudio.Component.VC.14.44.17.14.ATL.ARM64',
    'Microsoft.VisualStudio.Component.VC.ATL',
    'Microsoft.VisualStudio.Component.VC.ATL.ARM64',
    'Microsoft.VisualStudio.ComponentGroup.UWP.VC',
    'Microsoft.VisualStudio.Component.UWP.VC.ARM64',
    'Microsoft.VisualStudio.Component.UWP.VC.ARM64EC',
    'Microsoft.VisualStudio.Component.Windows11SDK.26100'
)
$vs = & $vswhere -version '[18.0,19.0)' -products * -requires $components -property installationPath | Select-Object -First 1
if (-not $vs) { throw 'No Visual Studio 2026 install has every component README.md lists.' }
$msbuild = Join-Path $vs 'MSBuild\Current\Bin\amd64\MSBuild.exe'
$vcpkg = Join-Path $vs 'VC\vcpkg'

function Invoke-MSBuild([string[]]$Arguments) {
    & $msbuild @Arguments '-m' '-nodeReuse:false' '-v:m' '-nologo'
    if ($LASTEXITCODE -ne 0) { throw "MSBuild exited with $LASTEXITCODE for $($Arguments[0])" }
}

# MajorLinkerVersion and MinorLinkerVersion follow the 2-byte Magic field of
# the optional header, which starts 24 bytes after the PE signature offset.
function Get-LinkerVersion([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $pe = [BitConverter]::ToInt32($bytes, 0x3C)
    return '{0}.{1}' -f $bytes[$pe + 26], $bytes[$pe + 27]
}

# --- Source -------------------------------------------------------------------

New-Item -ItemType Directory -Path $Workspace | Out-Null
$src = Join-Path $Workspace 'MIDI'
git clone --quiet --depth 1 --branch $Tag https://github.com/microsoft/MIDI.git $src
if ($LASTEXITCODE -ne 0) { throw 'git clone failed' }
$head = (git -C $src rev-parse HEAD).Trim()
if ($head -ne $Commit) { throw "Tag $Tag is $head, expected $Commit" }

$api = Join-Path $src 'src\api'
$appSdk = Join-Path $src 'src\app-sdk'

# --- Version includes ---------------------------------------------------------
# Microsoft's version numbers, with the build source naming this build.

Invoke-MSBuild @(
    (Join-Path $src 'src\build-gen-version-includes\GenVersionIncludes.csproj'),
    '-t:TransformAll',
    '-p:MidiBuildType=rc',
    '-p:MidiBuildSource=PadForge build of GitHub rc-4',
    "-p:MidiVersionName=$VersionName",
    "-p:MidiBuildVersionMajor=$Major",
    "-p:MidiBuildVersionMinor=$Minor",
    "-p:MidiBuildVersionPatch=$Patch",
    "-p:MidiBuildVersionBuildNumber=$BuildNumber",
    "-p:MidiBuildVersionPreviewString=$PreviewString",
    "-p:MidiVersionOutputFolder=$(Join-Path $src 'build\staging\version')"
)

# --- C++/WinRT headers ---------------------------------------------------------
# The runtime compiles against C++/WinRT 2.0.250303.1 from NuGet. The two API
# libraries it links take C++/WinRT from the Windows SDK, and SDK servicing
# releases ship newer headers (2.0.250303.5), which the linker refuses to mix
# (LNK2038). The libraries are compiled against the NuGet version instead.

Invoke-MSBuild @((Join-Path $appSdk 'app-sdk.sln'), '-t:Restore', '-p:RestorePackagesConfig=true')
$cppwinrt = Join-Path $appSdk 'packages\Microsoft.Windows.CppWinRT.2.0.250303.1\bin\cppwinrt.exe'
$winrtHeaders = Join-Path $Workspace 'cppwinrt'
& $cppwinrt -input $WindowsSdk -output $winrtHeaders
if ($LASTEXITCODE -ne 0) { throw 'cppwinrt failed' }

# --- API reference files, per platform -------------------------------------------
# What nuke_build-service stages into src\shared\api-ref\<platform> for the
# runtime to compile and link against.

$env:CL = "/I`"$winrtHeaders`""
try {
    foreach ($platform in 'x64', 'ARM64', 'ARM64EC') {
        $common = @('-restore', '-p:RestorePackagesConfig=true', '-p:Configuration=Release',
                    "-p:Platform=$platform", "-p:SolutionDir=$api\", '-p:NoWarn=MIDL2111')
        foreach ($project in 'idl\IDL.vcxproj', 'Libs\MidiKs\MidiKS.vcxproj',
                             'Libs\MidiPluginConfigurationLib\MidiPluginConfigurationLib.vcxproj',
                             'Libs\MidiEndpointNamingLib\MidiEndpointNamingLib.vcxproj') {
            Invoke-MSBuild (@((Join-Path $api $project)) + $common)
        }
        # Only the transport's MIDL header is needed. Its C++ sources include
        # an RPC header from the service build, which the runtime does not use.
        Invoke-MSBuild (@((Join-Path $api 'Transport\MidiSrvTransport\Midi2.MidiSrvTransport.vcxproj'), '-t:Midl') + $common)

        $ref = Join-Path $src "src\shared\api-ref\$platform"
        New-Item -ItemType Directory -Force -Path $ref | Out-Null
        $files = @(
            "vsfiles\intermediate\IDL\$platform\Release\WindowsMidiServices.h",
            "vsfiles\intermediate\IDL\$platform\Release\WindowsMidiServices_i.c",
            "vsfiles\intermediate\MidiKS\$platform\Release\MidiKS.lib",
            "vsfiles\$platform\Release\MidiPluginConfigurationLib.lib",
            "vsfiles\$platform\Release\MidiEndpointNamingLib.lib",
            "vsfiles\intermediate\Midi2.MidiSrvTransport\$platform\Release\Midi2MidiSrvTransport.h",
            'Transport\UdpNetworkMidi2Transport\network_json_defs.h'
        )
        foreach ($h in 'MidiEndpointCustomProperties.h', 'MidiEndpointMatchCriteria.h', 'MidiEndpointNameTable.h',
                       'MidiDefs.h', 'hstring_util.h', 'wstring_util.h', 'json_defs.h', 'json_helpers.h',
                       'loopback_ids.h', 'midi_group_terminal_blocks.h') {
            $files += "inc\$h"
        }
        foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path $api $f) -Destination $ref -Force }
    }
}
finally {
    Remove-Item Env:CL -ErrorAction SilentlyContinue
}

# --- Runtime -----------------------------------------------------------------------
# x64, and Arm64EC built as Arm64X: one DLL with native ARM64 and ARM64EC code,
# as Microsoft ships it. libmidi2 comes from vcpkg in manifest mode.

foreach ($platform in 'x64', 'Arm64EC') {
    Invoke-MSBuild @(
        (Join-Path $appSdk 'app-sdk.sln'),
        '-restore', '-p:RestorePackagesConfig=true', '-p:Configuration=Release',
        "-p:Platform=$platform", "-p:SolutionDir=$appSdk\", '-p:NoWarn=MSB3271',
        "-p:Version=$semVersion", "-p:VersionPrefix=$Major.$Minor.$Patch",
        "-p:AssemblyVersion=$fileVersion", "-p:FileVersion=$fileVersion",
        "-p:VcpkgRoot=$vcpkg",
        "-p:ForceImportBeforeCppTargets=$vcpkg\scripts\buildsystems\msbuild\vcpkg.props",
        "-p:ForceImportAfterCppTargets=$vcpkg\scripts\buildsystems\msbuild\vcpkg.targets"
    )
}

# --- Installers ----------------------------------------------------------------------

$out = Join-Path $Workspace 'out'
$symbols = Join-Path $Workspace 'symbols'
New-Item -ItemType Directory -Force -Path $out, $symbols | Out-Null
$runtimeOut = Join-Path $appSdk 'vsfiles\out\Microsoft.Windows.Devices.Midi2'
$assets = @()
foreach ($pair in @(@('x64', 'x64'), @('ARM64', 'ARM64EC'))) {
    $platform = $pair[0]
    $bin = Join-Path $runtimeOut "$($pair[1])\Release"
    $dll = Join-Path $bin 'Microsoft.Windows.Devices.Midi2.dll'
    $info = (Get-Item $dll).VersionInfo
    if ($info.FileVersion -ne $fileVersion) { throw "$dll is $($info.FileVersion), expected $fileVersion" }
    $linker = Get-LinkerVersion $dll
    Write-Host "$platform runtime $($info.ProductVersion), linker $linker"

    # --no-incremental: the binary paths and the runtime minimum arrive as
    # preprocessor values, and an incremental build that sees no changed
    # .wxs reuses objects compiled with the previous run's values.
    & dotnet build (Join-Path $repoRoot 'installer\PadForgeMidiRuntime.wixproj') -c Release -nologo -v:m --no-incremental `
        "-p:Platform=$platform" "-p:BinDir=$bin" "-p:ProductVersion=$fileVersion" `
        "-p:VcRuntimeMinVersion=$linker" -o (Join-Path $Workspace "msi\$platform")
    if ($LASTEXITCODE -ne 0) { throw "The $platform installer build failed" }

    $name = "PadForge-MIDI-Runtime-$semVersion-$($platform.ToLowerInvariant()).msi"
    Copy-Item -LiteralPath (Join-Path $Workspace "msi\$platform\PadForge-MIDI-Runtime-$platform.msi") -Destination (Join-Path $out $name)
    $assets += $name

    $symDir = Join-Path $symbols $platform.ToLowerInvariant()
    New-Item -ItemType Directory -Force -Path $symDir | Out-Null
    Copy-Item -LiteralPath $dll, (Join-Path $bin 'Microsoft.Windows.Devices.Midi2.pdb') -Destination $symDir
}

$zip = "PadForge-MIDI-Runtime-$semVersion-symbols.zip"
Compress-Archive -Path (Join-Path $symbols '*') -DestinationPath (Join-Path $out $zip)
$assets += $zip

$sums = foreach ($a in $assets) {
    '{0}  {1}' -f (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $out $a)).Hash.ToLowerInvariant(), $a
}
[System.IO.File]::WriteAllLines((Join-Path $out 'SHA256SUMS.txt'), [string[]]$sums)
$sums | ForEach-Object { Write-Host $_ }
