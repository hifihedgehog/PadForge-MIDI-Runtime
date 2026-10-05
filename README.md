# PadForge MIDI Runtime

Builds of Microsoft's Windows MIDI Services App SDK runtime, version 1.0.17-rc.4.25, for Windows 11 PCs that do not have the API built in.

Microsoft removed the runtime installers from its releases on October 1, 2026. The API moves into Windows 11 25H2 with the late-November 2026 update. Until a PC has that update, and on Windows 11 24H2, which never gets it, an app built on the Windows MIDI Services App SDK needs this runtime installed. [PadForge](https://github.com/hifihedgehog/PadForge) downloads it from this repository's releases when a PC needs it. Any other app built on the App SDK can use it the same way.

A PC whose Windows already includes the API does not need this package. Windows Update is the official source there.

## Downloads

Each [release](https://github.com/hifihedgehog/PadForge-MIDI-Runtime/releases) carries:

- `PadForge-MIDI-Runtime-<version>-x64.msi` for x64 PCs.
- `PadForge-MIDI-Runtime-<version>-arm64.msi` for ARM64 PCs. Its DLL is Arm64X, as Microsoft ships it, so x64 apps running under emulation load it too.
- `PadForge-MIDI-Runtime-<version>-symbols.zip`, the DLLs with their PDB files.
- `SHA256SUMS.txt`.

## Installing

1. Install the Microsoft Visual C++ Redistributable 14.51 or later from https://aka.ms/vc14/vc_redist.x64.exe. The x64 package carries the ARM64 files as well, so ARM64 PCs use it too. Setup checks for it and stops with a message when it is missing or older.
2. Run the MSI for the PC.

Setup refuses to install over Microsoft's own copy of the runtime, because both would own the same registry value. Uninstall from Settings, Apps, like any other app.

## What it installs

- `C:\Program Files\PadForge MIDI Runtime\` with `Microsoft.Windows.Devices.Midi2.dll`, `.winmd` and `.pri`, plus the license notices.
- The COM registration of the runtime's `MidiClientInitializer` class, written by the DLL's own `DllRegisterServer`, as in Microsoft's package.
- `HKLM\SOFTWARE\Microsoft\Windows MIDI Services\Desktop App SDK Runtime`, value `Installed`, pointing at that folder. The runtime finds its files through this value.

Microsoft's package also installed the MIDI Settings app, the MIDI console, a PowerShell module and command-line diagnostic tools. This package carries only the runtime.

## Building

`build\build.ps1` clones [microsoft/MIDI](https://github.com/microsoft/MIDI) at tag `rc-4` (commit `d1d274a67102c28a94b6a96d262f7071d5ee7281`), builds the parts the runtime needs for x64, ARM64 and ARM64EC, and packages both installers with WiX 5.

```
powershell -ExecutionPolicy Bypass -File build\build.ps1 -Workspace C:\mb-build
```

The workspace must be a new folder whose path has no spaces. The build needs git, the .NET 10 SDK and Visual Studio 2026 with the C++ desktop and Universal Windows Platform tools for x64, ARM64 and ARM64EC, the MSVC v143 14.44 toolset with ATL, and the Windows 11 SDK 10.0.26100. The script lists the exact component IDs and stops when one is missing.

The build differs from Microsoft's in two places:

- The version files name the build source `PadForge build of GitHub rc-4` and carry the real build date. The version numbers are Microsoft's.
- Two API libraries the runtime links, MidiPluginConfigurationLib and MidiEndpointNamingLib, compile against C++/WinRT 2.0.250303.1, the version the runtime itself uses. Current Windows SDK servicing releases ship 2.0.250303.5 headers, and the linker refuses to combine the two (LNK2038).

The output is not byte-for-byte reproducible, since the linker stamps times and PDB identifiers. The x64 DLL matches Microsoft's rc.4.25 DLL in its exports, imported DLLs and version resources. It was linked by MSVC 14.51 where Microsoft's was linked by 14.50, which is why setup asks for the 14.51 redistributable.

## License

The runtime is Microsoft's code, released under the MIT License in [LICENSE](LICENSE). [THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt) lists the components compiled into the DLL. The build and packaging files in this repository are released under the same license.

This project is not affiliated with Microsoft. Windows is a trademark of the Microsoft group of companies.
