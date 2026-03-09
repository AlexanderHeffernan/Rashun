$ErrorActionPreference = "Stop"

$Repo = "alexanderheffernan/rashun"
$DownloadUrl = "https://github.com/$Repo/releases/latest/download/rashun-cli-windows.zip"
$BinDir = Join-Path $HOME ".local\bin"
$TargetExe = Join-Path $BinDir "rashun.exe"
$TempDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ("rashun-install-" + [guid]::NewGuid()))

function Add-ToUserPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathEntry
    )

    $normalized = $PathEntry.Trim().TrimEnd('\\')
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")

    $existingEntries = @()
    if (-not [string]::IsNullOrWhiteSpace($userPath)) {
        $existingEntries = $userPath -split ';' |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }

    $exists = $existingEntries |
        Where-Object { $_.TrimEnd('\\') -ieq $normalized } |
        Select-Object -First 1

    if ($exists) {
        return $false
    }

    $newUserPath = if ([string]::IsNullOrWhiteSpace($userPath)) {
        $PathEntry
    } else {
        "$userPath;$PathEntry"
    }

    [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
    return $true
}

try {
    $ZipPath = Join-Path $TempDir.FullName "rashun-cli-windows.zip"
    $ExtractDir = Join-Path $TempDir.FullName "extract"

    Invoke-WebRequest -Uri $DownloadUrl -OutFile $ZipPath

    Expand-Archive -Path $ZipPath -DestinationPath $ExtractDir -Force
    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null

    $exe = Get-ChildItem -Path $ExtractDir -Filter "rashun.exe" -File -Recurse | Select-Object -First 1
    if (-not $exe) {
        throw "Installer payload is missing rashun.exe"
    }

    $payloadDir = $exe.Directory.FullName
    Get-ChildItem -Path $payloadDir -File | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination (Join-Path $BinDir $_.Name) -Force
    }

    $pathChanged = Add-ToUserPath -PathEntry $BinDir

    $currentPathHasBin = ($env:Path -split ';' |
        ForEach-Object { $_.Trim().TrimEnd('\\') } |
        Where-Object { $_ -ieq $BinDir.TrimEnd('\\') } |
        Select-Object -First 1)
    if (-not $currentPathHasBin) {
        $env:Path = "$BinDir;$env:Path"
    }

    $helpOutput = & $TargetExe --help 2>&1 | Out-String
    $helpExitCode = $LASTEXITCODE
    if ($helpExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($helpOutput)) {
        throw "Installed binary did not return valid help output (exit code: $helpExitCode)."
    }

    Write-Host "Installed: $TargetExe"
    if ($pathChanged) {
        Write-Host "Added '$BinDir' to your user PATH."
        Write-Host "Open a new PowerShell session to use 'rashun' globally."
    } else {
        Write-Host "'$BinDir' is already on your user PATH."
    }
    Write-Host "Validation passed: rashun --help"
}
finally {
    Remove-Item -Recurse -Force $TempDir.FullName
}
