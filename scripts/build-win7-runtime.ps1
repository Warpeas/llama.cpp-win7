<#
    Win7 runtime packaging notes
    ----------------------------
    This script was validated in a local Windows 10/11 x64 environment using:
      - Visual Studio 2022 with C++ Desktop workload
      - LLVM/Clang toolchain + Ninja + CMake
      - MSYS2 UCRT64 shell or a Windows shell with cmake in PATH
    It is intentionally a compatibility fork for building llama.cpp targets that
    run on Windows 7 SP1 x64. The compatibility layer is opt-in via LLAMA_WIN7_COMPAT
    and is not enabled in a normal upstream build.

    Example invocation (PowerShell):
            pwsh -NoProfile -File ./scripts/build-win7-runtime.ps1 -Mode cpu -BuildDir build-win7-portable-msys2
            pwsh -NoProfile -File ./scripts/build-win7-runtime.ps1 -Mode cpu -BuildDir build-win7-portable-msys2 -CleanBuildDir
        If you use -ExternalUi, build UI assets first from tools/ui:
            cd tools/ui
            npm run build
        Add -ExternalUi to ship a separate ui\ directory while keeping the embedded fallback.
        The existing build directory is kept by default; use -CleanBuildDir for a clean rebuild.
#>
param(
    [ValidateSet("cpu", "vulkan", "openvino")]
    [string]$Mode = "cpu",
    [string]$BuildDir = "build-win7-portable-msys2",
    [string]$InstallSubDir = "dist",
    [string]$ZipPrefix = "llama-win7",
    [int]$Jobs = 8,
    [switch]$ExternalUi,
    [switch]$CleanBuildDir,
    [switch]$NoZip,
    [string]$OpenVinoSetupScript = "C:\Intel\openvino\setupvars.ps1",
    [string]$VcpkgToolchain = "C:\vcpkg\scripts\buildsystems\vcpkg.cmake",
    [string]$VulkanSdkRoot = "C:\VulkanSDK"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Resolve-CMakePath {
    $cmake = Get-Command cmake -ErrorAction SilentlyContinue
    if (-not $cmake) {
        throw "cmake not found in PATH. Please install CMake in your MSYS2 UCRT64 environment first."
    }

    return $cmake.Source
}

function Copy-IfExists([string]$Source, [string]$Destination) {
    if (Test-Path $Source) {
        Copy-Item -Path $Source -Destination $Destination -Force
        return $true
    }

    return $false
}

function Remove-Or-RenameDirectory([string]$PathToRemove, [string]$Reason) {
    if (-not (Test-Path $PathToRemove)) {
        return
    }

    Write-Step "${Reason}: $PathToRemove"
    try {
        Remove-Item -Recurse -Force $PathToRemove
        return
    }
    catch {
        $fallback = "{0}.stale-{1}" -f $PathToRemove, (Get-Date -Format "yyyyMMdd-HHmmss")
        Write-Host "Directory is busy, renaming to: $fallback" -ForegroundColor Yellow
        Rename-Item -Path $PathToRemove -NewName (Split-Path -Path $fallback -Leaf)
        return
    }
}

function Get-AvailableBuildDir([string]$BaseDir) {
    if (-not (Test-Path $BaseDir)) {
        return $BaseDir
    }

    for ($i = 1; $i -le 50; $i++) {
        $candidate = "{0}-{1}" -f $BaseDir, $i
        if (-not (Test-Path $candidate)) {
            return $candidate
        }
    }

    throw "Failed to allocate a new build directory from base: $BaseDir"
}

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

$buildPath = Join-Path $RepoRoot $BuildDir
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$zipPath = Join-Path $buildPath ("{0}-{1}-{2}.zip" -f $ZipPrefix, $Mode, $timestamp)
$cmakePath = Resolve-CMakePath
$cmakeBinDir = Split-Path -Path $cmakePath -Parent

$extraCmakeArgs = @(
    # Win7: the core switch. Adds -D_WIN32_WINNT=0x0601 and the LLAMA_WIN7_COMPAT
    # macro, keeping Win8+ APIs out of the import table. Do not remove.
    "-DLLAMA_WIN7_COMPAT=ON",

    # Build shape. Shared libs are required: the package ships runtime DLLs.
    "-G", "Ninja",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DBUILD_SHARED_LIBS=ON",

    # Binaries to ship.
    "-DLLAMA_BUILD_APP=ON",
    "-DLLAMA_BUILD_TOOLS=ON",
    # server is built by default; uncomment to leave it out
    # "-DLLAMA_BUILD_SERVER=OFF",

    # Web UI (see README for the full asset priority order).
    "-DLLAMA_BUILD_UI=ON",          # falls back to an npm build
    "-DLLAMA_USE_PREBUILT_UI=OFF",  # never download UI assets from HF
    # Required by --tools and MCP child-process support. Default is ON
    # "-DLLAMA_SUBPROCESS=ON",

    # CPU optimization
    # GGML_NATIVE defaults to ON for native builds and OFF for cross-compiling.
    # Set it explicitly when building for a specific target platform.
    # "-DGGML_NATIVE=OFF",

    # Trim what is not shipped.
    "-DLLAMA_BUILD_TESTS=OFF",
    "-DLLAMA_BUILD_EXAMPLES=OFF",
    "-DBUILD_TESTING=OFF",
    "-DGGML_BUILD_TESTS=OFF",

    # No OpenSSL: no HTTPS support, but no OpenSSL DLLs to ship either.
    "-DLLAMA_OPENSSL=OFF",
    # RPC adds backend DLLs to the package
    # "-DGGML_RPC=OFF",

    # ccache and OpenMP add nothing to a one-off packaging build.
    "-DGGML_CCACHE=OFF",
    "-DGGML_OPENMP=OFF"
)

switch ($Mode) {
    "cpu" {
        # Keep default CPU-only mode.
    }
    "vulkan" {
        $extraCmakeArgs += "-DGGML_VULKAN=ON"
        if (-not (Test-Path $VulkanSdkRoot)) {
            throw "Vulkan SDK root not found: $VulkanSdkRoot. Install LunarG Vulkan SDK first."
        }
    }
    "openvino" {
        if (-not (Test-Path $OpenVinoSetupScript)) {
            throw "OpenVINO setup script not found: $OpenVinoSetupScript"
        }
        Write-Step "Initializing OpenVINO environment: $OpenVinoSetupScript"
        & $OpenVinoSetupScript
        if (-not (Test-Path $VcpkgToolchain)) {
            throw "vcpkg toolchain not found: $VcpkgToolchain"
        }
        $extraCmakeArgs += "-DGGML_OPENVINO=ON", "-DCMAKE_TOOLCHAIN_FILE=$VcpkgToolchain"
    }
}

if ($CleanBuildDir -and (Test-Path $buildPath)) {
    try {
        Remove-Or-RenameDirectory -PathToRemove $buildPath -Reason "Cleaning previous build directory"
    }
    catch {
        $newBuildDir = Get-AvailableBuildDir -BaseDir $BuildDir
        Write-Host "Build directory is locked, switching to: $newBuildDir" -ForegroundColor Yellow
        $BuildDir = $newBuildDir
    }
}

$buildPath = Join-Path $RepoRoot $BuildDir
$installPath = Join-Path $buildPath (Join-Path $InstallSubDir $Mode)
$runtimeDir = Join-Path $buildPath ("runtime-{0}" -f $Mode)
$zipPath = Join-Path $buildPath ("{0}-{1}-{2}.zip" -f $ZipPrefix, $Mode, $timestamp)

Write-Step "Configuring (mode: $Mode, generator: Ninja)"
& $cmakePath -S . -B $BuildDir @extraCmakeArgs

Write-Step "Building"
& $cmakePath --build $BuildDir -j $Jobs

if (Test-Path $installPath) {
    Write-Step "Cleaning previous install directory: $installPath"
    Remove-Item -Recurse -Force $installPath
}

Write-Step "Installing to build-local dist directory"
& $cmakePath --install $BuildDir --prefix $installPath

if (-not $NoZip) {
    if (Test-Path $runtimeDir) {
        Remove-Or-RenameDirectory -PathToRemove $runtimeDir -Reason "Cleaning previous runtime staging directory"
    }

    $binDir = Join-Path $installPath "bin"
    if (-not (Test-Path $binDir)) {
        throw "Expected runtime bin directory not found: $binDir"
    }

    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
    $runtimeFiles = @(
        Get-ChildItem -Path $binDir -File -ErrorAction Stop |
        Where-Object {
            $_.Extension -in '.exe', '.dll'
        }
    )
    if ($runtimeFiles.Count -eq 0) {
        throw "No EXE/DLL runtime files were found in $binDir. Nothing to package."
    }

    foreach ($file in $runtimeFiles) {
        Copy-Item -Path $file.FullName -Destination $runtimeDir -Force
    }

    if ($ExternalUi) {
        $uiSourceDir = Join-Path $RepoRoot "tools\ui\dist"
        $uiTargetDir = Join-Path $runtimeDir "ui"
        if (-not (Test-Path (Join-Path $uiSourceDir "index.html"))) {
            throw "External UI assets not found: $uiSourceDir. Run npm run build in tools/ui first."
        }

        Write-Step "Copying external UI assets"
        New-Item -ItemType Directory -Force -Path $uiTargetDir | Out-Null
        Copy-Item -Path (Join-Path $uiSourceDir "*") -Destination $uiTargetDir -Recurse -Force
    }

    # Ensure MinGW runtime DLLs are available after extracting the zip on Win7.
    $runtimeDlls = @(
        "libstdc++-6.dll",
        "libgcc_s_seh-1.dll",
        "libwinpthread-1.dll"
    )
    foreach ($dll in $runtimeDlls) {
        $src = Join-Path $cmakeBinDir $dll
        if (-not (Copy-IfExists -Source $src -Destination $runtimeDir)) {
            Write-Host "Warning: runtime DLL not found next to cmake: $src" -ForegroundColor Yellow
        }
    }

    Write-Step "Creating runtime-only zip package"
    Compress-Archive -Path (Join-Path $runtimeDir "*") -DestinationPath $zipPath -CompressionLevel Optimal -Force
    if (-not (Test-Path $zipPath)) {
        throw "Zip archive was not created at $zipPath. Check the runtime staging directory and the source bin files."
    }

    $sizeMiB = [math]::Round(((Get-Item $zipPath).Length / 1MB), 2)
    Write-Host "Runtime   : $runtimeDir"
    Write-Host "Zip       : $zipPath ($sizeMiB MiB)"
}
else {
    Write-Step "Skipping zip packaging as requested"
}

Write-Step "Done"
Write-Host "Build dir : $buildPath"
Write-Host "Install   : $installPath"
if (-not $NoZip) {
    Write-Host "Runtime   : $runtimeDir"
}
