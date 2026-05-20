<#
.SYNOPSIS
  Creates a tiny placeholder zip used as the "build artifact" in the
  reproduction pipelines.

.DESCRIPTION
  Produces $OutDir/rcm-operations-$Version.zip containing a single
  text file. Keeps everything self-contained so we don't have to commit
  binaries to the repository.
#>
param(
    [string]$Version = "3.4.1",
    [string]$OutDir  = "$PSScriptRoot/../out"
)

$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$stage = Join-Path $OutDir "stage"
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$payload = Join-Path $stage "README.txt"
@"
rcm-operations $Version
Generated for the JFrog build-promotion silent-success reproduction.
This file is meant to be uploaded to <source-repo>/rcm-operations/ via
the JFrog Generic Artifacts task, then promoted to <target-repo>.
"@ | Set-Content -Path $payload -Encoding UTF8

$zipPath = Join-Path $OutDir "rcm-operations-$Version.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath -Force

Write-Host "Created $zipPath"
Get-Item $zipPath | Select-Object FullName, Length
