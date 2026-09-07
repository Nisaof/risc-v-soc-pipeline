param(
    [ValidateSet("synth", "impl", "strategy", "build")]
    [string]$Mode = "synth",

    [ValidateSet("explore", "aggressive", "postroute")]
    [string]$Strategy = "explore",

    [string]$VivadoBat = "C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"
)

$ErrorActionPreference = "Stop"

$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$BuildDir = Join-Path $RepoRoot "build\fpga"
$BuildTcl = Join-Path $PSScriptRoot "build.tcl"
$BootMem  = Join-Path $RepoRoot "sw\tests\bootloader.mem"

if (-not (Test-Path -LiteralPath $VivadoBat -PathType Leaf)) {
    throw "Vivado launcher not found: $VivadoBat"
}
if (-not (Test-Path -LiteralPath $BuildTcl -PathType Leaf)) {
    throw "Vivado Tcl flow not found: $BuildTcl"
}
if (-not (Test-Path -LiteralPath $BootMem -PathType Leaf)) {
    throw "Required bootloader image is missing: $BootMem. Run 'make fpga_bootloader' in WSL first."
}

New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
$LogStem = if ($Mode -eq "strategy") { "{0}_{1}" -f $Mode, $Strategy } else { $Mode }
$LogFile = Join-Path $BuildDir ("vivado_{0}_win.log" -f $LogStem)

Write-Host "Vivado launcher : $VivadoBat"
Write-Host "Repository      : $RepoRoot"
Write-Host "Tcl flow        : $BuildTcl"
Write-Host "Build mode      : $Mode"
if ($Mode -eq "strategy") {
    Write-Host "Strategy        : $Strategy"
}

# All paths passed to Vivado are absolute Windows/UNC paths. build.tcl derives
# every RTL, constraints, memory, and output path from its own location, so the
# same non-project flow is shared by native Linux and Windows Vivado.
$TclArgs = @($Mode)
if ($Mode -eq "strategy") {
    $TclArgs += $Strategy
}
& $VivadoBat -mode batch -nojournal -log $LogFile -source $BuildTcl -tclargs $TclArgs
$VivadoExitCode = $LASTEXITCODE

if ($VivadoExitCode -ne 0) {
    throw "Vivado exited with code $VivadoExitCode; see $LogFile"
}

exit 0
