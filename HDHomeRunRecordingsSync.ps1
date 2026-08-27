param(
    [string]$HdHomeRun = "http://hdhomerun.local",
    [string]$DestinationRoot = "D:\Media\TV",
    [int]$CompletionBufferSeconds = 90
)

$ErrorActionPreference = "Stop"
$ScriptVersion = "1.0.0"

$LogDir = Join-Path $PSScriptRoot "logs"
$LogFile = Join-Path $LogDir "hdhomerun-archive.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-Log {
    param([string]$Message)

    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Message"
    Add-Content -Path $LogFile -Value $line
    Write-Host $line
}

function Get-SafeName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ""
    }

    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) {
        $Name = $Name.Replace($c, '_')
    }

    return $Name.Trim().TrimEnd('.')
}

function Get-UnixTime {
    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

function Get-EpisodeDestination {
    param($Episode)

    $title = Get-SafeName $Episode.Title
    $episodeTitle = Get-SafeName $Episode.EpisodeTitle
    $episodeNumber = [string]$Episode.EpisodeNumber

    $showDir = Join-Path $DestinationRoot $title
    $fileBase = $title

    if ($episodeNumber -match '^S(\d+)E(\d+)$') {
        $seasonNumber = [int]$matches[1]
        $seasonDir = Join-Path $showDir ("Season {0:D2}" -f $seasonNumber)
        New-Item -ItemType Directory -Force -Path $seasonDir | Out-Null

        $fileBase += " - $episodeNumber"
        if ($episodeTitle) {
            $fileBase += " - $episodeTitle"
        }

        return Join-Path $seasonDir ((Get-SafeName $fileBase) + ".mpg")
    }

    New-Item -ItemType Directory -Force -Path $showDir | Out-Null

    $airDate = $null

    if ($Episode.OriginalAirdate -and [int64]$Episode.OriginalAirdate -gt 0) {
        try {
            $airDate = [DateTimeOffset]::FromUnixTimeSeconds(
                [int64]$Episode.OriginalAirdate
            ).ToLocalTime().ToString("yyyy-MM-dd")
        }
        catch {}
    }

    if (-not $airDate -and $Episode.StartTime) {
        try {
            $airDate = [DateTimeOffset]::FromUnixTimeSeconds(
                [int64]$Episode.StartTime
            ).ToLocalTime().ToString("yyyy-MM-dd")
        }
        catch {}
    }

    if ($airDate) {
        $fileBase += " - $airDate"
    }

    if ($episodeTitle) {
        $fileBase += " - $episodeTitle"
    }

    return Join-Path $showDir ((Get-SafeName $fileBase) + ".mpg")
}

function Test-Destination {
    if (-not (Test-Path -LiteralPath $DestinationRoot -PathType Container)) {
        Write-Log "OFFLINE: Destination is not accessible: $DestinationRoot. Nothing will be copied or deleted."
        return $false
    }

    $writeTest = Join-Path $DestinationRoot (
        ".hdhomerun_write_test_{0}.tmp" -f ([Guid]::NewGuid().ToString("N"))
    )

    try {
        [IO.File]::WriteAllText($writeTest, "test")
        Remove-Item -LiteralPath $writeTest -Force
    }
    catch {
        if (Test-Path -LiteralPath $writeTest) {
            Remove-Item -LiteralPath $writeTest -Force -ErrorAction SilentlyContinue
        }

        Write-Log "OFFLINE/READ-ONLY: Destination is not writable: $DestinationRoot. Nothing will be copied or deleted."
        return $false
    }

    Write-Log "DESTINATION OK: $DestinationRoot is accessible and writable."
    return $true
}

function Download-Recording {
    param(
        [string]$Url,
        [string]$Destination
    )

    $partial = "$Destination.partial"

    if (Test-Path -LiteralPath $Destination) {
        Write-Log "SKIP: Destination already exists; source will NOT be deleted: $Destination"
        return $false
    }

    if (Test-Path -LiteralPath $partial) {
        Remove-Item -LiteralPath $partial -Force
    }

    $destDir = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null

    Write-Log "COPY: $Url -> $Destination"

    & curl.exe --fail --location --silent --show-error --output $partial $Url
    $curlExit = $LASTEXITCODE

    if ($curlExit -ne 0) {
        Write-Log "ERROR: curl failed with exit code $curlExit. Source retained."

        if (Test-Path -LiteralPath $partial) {
            Remove-Item -LiteralPath $partial -Force
        }

        return $false
    }

    if (-not (Test-Path -LiteralPath $partial)) {
        Write-Log "ERROR: Download produced no file. Source retained."
        return $false
    }

    $size = (Get-Item -LiteralPath $partial).Length

    if ($size -lt 1048576) {
        Write-Log "ERROR: Downloaded file is suspiciously small ($size bytes). Source retained."
        Remove-Item -LiteralPath $partial -Force
        return $false
    }

    Move-Item -LiteralPath $partial -Destination $Destination -Force

    if (-not (Test-Path -LiteralPath $Destination)) {
        Write-Log "ERROR: Final file missing after move. Source retained."
        return $false
    }

    $finalSize = (Get-Item -LiteralPath $Destination).Length

    if ($finalSize -ne $size) {
        Write-Log "ERROR: Final size mismatch ($finalSize vs $size). Source retained."
        return $false
    }

    Write-Log "COPIED: $Destination ($finalSize bytes)"
    return $true
}

function Delete-Recording {
    param([string]$CmdUrl)

    $separator = "?"
    if ($CmdUrl.Contains("?")) {
        $separator = "&"
    }

    $deleteUrl = "${CmdUrl}${separator}cmd=delete&rerecord=0"

    Write-Log "DELETE: Removing successfully archived recording from HDHomeRun."

    & curl.exe --fail --silent --show-error --request POST $deleteUrl | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Log "ERROR: HDHomeRun delete command failed. Archived copy remains safe."
        return $false
    }

    Write-Log "DELETED: HDHomeRun source removed."
    return $true
}

try {
    Write-Log "----- Scan started -----"
    Write-Log "Script version: $ScriptVersion"

    if (-not (Test-Destination)) {
        exit 0
    }

    $seriesUrl = "$HdHomeRun/recorded_files.json"
    $seriesList = Invoke-RestMethod -Uri $seriesUrl -Method Get

    if (-not $seriesList) {
        Write-Log "No recordings found."
        exit 0
    }

    $now = Get-UnixTime

    foreach ($series in @($seriesList)) {
        if (-not $series.EpisodesURL) {
            Write-Log "WARN: No EpisodesURL for '$($series.Title)'."
            continue
        }

        Write-Log "FOUND SERIES: $($series.Title)"

        $episodes = Invoke-RestMethod -Uri $series.EpisodesURL -Method Get

        foreach ($episode in @($episodes)) {
            $recordEnd = [int64]$episode.RecordEndTime

            if (-not $recordEnd -or $recordEnd -gt ($now - $CompletionBufferSeconds)) {
                Write-Log "WAIT: '$($episode.Title)' '$($episode.EpisodeNumber)' is still recording or just finished."
                continue
            }

            if (-not $episode.PlayURL -or -not $episode.CmdURL) {
                Write-Log "WARN: Missing PlayURL/CmdURL for '$($episode.Filename)'."
                continue
            }

            $destination = Get-EpisodeDestination $episode

            $copied = Download-Recording `
                -Url ([string]$episode.PlayURL) `
                -Destination $destination

            if ($copied) {
                Delete-Recording -CmdUrl ([string]$episode.CmdURL) | Out-Null
            }
        }
    }

    Write-Log "----- Scan finished -----"
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)"
    exit 1
}
