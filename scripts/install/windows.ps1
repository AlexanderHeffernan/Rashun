$ErrorActionPreference = "Stop"

$Repo = "alexanderheffernan/rashun"
$DownloadUrl = "https://github.com/$Repo/releases/latest/download/rashun-cli-windows.zip"
$BinDir = Join-Path $HOME ".local\bin"
$Target = Join-Path $BinDir "rashun.exe"
$TempDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ("rashun-install-" + [guid]::NewGuid()))

try {
    $ZipPath = Join-Path $TempDir.FullName "rashun-cli-windows.zip"
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $ZipPath

    Expand-Archive -Path $ZipPath -DestinationPath $TempDir.FullName -Force
    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
    Move-Item -Path (Join-Path $TempDir.FullName "rashun.exe") -Destination $Target -Force

    Write-Host "Installed: $Target"
    Write-Host "Ensure '$BinDir' is on your PATH."
}
finally {
    Remove-Item -Recurse -Force $TempDir.FullName
}
