# HDHomeRun Recording Sync

A small PowerShell script for Windows that automatically moves completed recordings from an HDHomeRun FLEX DVR to another storage location, such as an Emby TV library, NAS, media server, or local disk.

After a recording finishes, the script:

1. Checks that the destination exists and is writable.
2. Reads the HDHomeRun DVR recording list.
3. Ignores recordings that are still in progress.
4. Downloads each completed recording to a temporary `.partial` file.
5. Verifies that the copied file exists and has a reasonable file size.
6. Renames the temporary file to its final `.mpg` filename.
7. Deletes the original recording from the HDHomeRun only after the copy succeeds.

This makes the HDHomeRun's attached USB storage useful as a temporary DVR buffer while another system provides long-term storage.

## Requirements

- Windows with Windows PowerShell or PowerShell
- `curl.exe` available in PATH
  - Included with current versions of Windows 10 and Windows 11
- An HDHomeRun model with DVR storage available through `recorded_files.json`
- A writable destination folder
- The Windows computer and HDHomeRun must be able to reach each other over the network

## Configuration

The script accepts three parameters:

```powershell
param(
    [string]$HdHomeRun = "http://hdhomerun.local",
    [string]$DestinationRoot = "D:\Media\TV",
    [int]$CompletionBufferSeconds = 90
)
```

### HDHomeRun address

By default the script uses:

```text
http://hdhomerun.local
```

If name resolution does not work on your network, use the HDHomeRun's IP address instead:

```powershell
-HdHomeRun "http://192.168.1.50"
```

A static DHCP reservation is recommended if you use an IP address.

### Destination

The default destination is:

```text
D:\Media\TV
```

You can override it without editing the script:

```powershell
-DestinationRoot "V:\IPTV_Recordings"
```

For unattended scheduled tasks, a UNC path is generally more reliable than a mapped drive letter:

```powershell
-DestinationRoot "\\NAS\Media\TV"
```

Mapped drives such as `V:` are associated with a Windows login session and may not be visible when Task Scheduler runs under a different account or security context.

## Running manually

Example:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "C:\Scripts\HDHomeRunRecordingsSync.ps1" `
  -HdHomeRun "http://192.168.1.50" `
  -DestinationRoot "\\NAS\Media\TV"
```

If the defaults already match your setup:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "C:\Scripts\HDHomeRunRecordingsSync.ps1"
```

## Folder and filename layout

When HDHomeRun provides conventional season and episode metadata, files are stored as:

```text
Destination
└── Show Name
    └── Season 09
        └── Show Name - S09E08 - Episode Title.mpg
```

For recordings without `SxxExx` metadata, the script falls back to a date-based filename:

```text
Destination
└── Show Name
    └── Show Name - 2026-08-27 - Episode Title.mpg
```

This structure works well with media servers such as Emby, Jellyfin, and Plex.

## Safety behavior

The script is intentionally conservative about deletion.

The HDHomeRun recording is **not deleted** when:

- the destination folder is unavailable
- the destination is read-only
- the recording is still in progress
- the download fails
- the downloaded file is missing
- the downloaded file is suspiciously small
- the final file cannot be verified
- a file with the same destination filename already exists

Deletion occurs only after the new file has been successfully downloaded and verified.

The HDHomeRun delete request uses:

```text
cmd=delete&rerecord=0
```

`rerecord=0` tells the HDHomeRun DVR not to automatically re-record the same airing as a replacement for the deleted recording.

## Destination availability check

Before contacting the recording list, the script verifies the destination by:

1. Checking that the directory exists.
2. Creating a temporary test file.
3. Deleting the temporary file.

If either operation fails, the script exits without copying or deleting any recordings.

Example log entry:

```text
OFFLINE: Destination is not accessible: \\NAS\Media\TV. Nothing will be copied or deleted.
```

This is useful when the archive location is a NAS, removable disk, mapped drive, or another machine that may occasionally be offline.

## Logs

Logs are stored relative to the script:

```text
logs\hdhomerun-archive.log
```

Example:

```text
2026-08-27 16:46:25  ----- Scan started -----
2026-08-27 16:46:25  Script version: 1.0.0
2026-08-27 16:46:25  DESTINATION OK: V:\IPTV_Recordings is accessible and writable.
2026-08-27 16:46:25  FOUND SERIES: Example Show
2026-08-27 16:46:25  COPY: http://hdhomerun.local/recorded/play?id=... -> V:\IPTV_Recordings\Example Show\Season 01\Example Show - S01E01.mpg
2026-08-27 16:46:41  COPIED: V:\IPTV_Recordings\Example Show\Season 01\Example Show - S01E01.mpg (186026376 bytes)
2026-08-27 16:46:41  DELETE: Removing successfully archived recording from HDHomeRun.
2026-08-27 16:46:42  DELETED: HDHomeRun source removed.
2026-08-27 16:46:42  ----- Scan finished -----
```

## Run automatically every 15 minutes

Windows Task Scheduler works well for this.

### General

Create a task named something like:

```text
HDHomeRun Recording Sync
```

Use the Windows account that has permission to write to the destination.

If you use a mapped drive such as `V:`, initially choose:

```text
Run only when user is logged on
```

A UNC destination such as `\\NAS\Media\TV` is preferable if the task must run while nobody is logged in.

### Trigger

Create a daily trigger and configure:

```text
Repeat task every: 15 minutes
For a duration of: Indefinitely
```

Enable:

```text
Run task as soon as possible after a scheduled start is missed
```

### Action

Program:

```text
powershell.exe
```

Arguments:

```text
-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Scripts\HDHomeRunRecordingsSync.ps1" -HdHomeRun "http://hdhomerun.local" -DestinationRoot "\\NAS\Media\TV"
```

Start in:

```text
C:\Scripts
```

### Prevent overlapping copies

Under Task Scheduler's **Settings** tab, set:

```text
If the task is already running:
Do not start a new instance
```

This prevents a second copy operation from starting if a large recording takes longer than 15 minutes to transfer.

## How HDHomeRun access works

The script uses the HDHomeRun FLEX DVR's local HTTP endpoints.

The root recording endpoint returns recorded series:

```text
http://hdhomerun.local/recorded_files.json
```

Each series provides an `EpisodesURL`, which returns recording metadata such as:

- `Title`
- `EpisodeNumber`
- `EpisodeTitle`
- `OriginalAirdate`
- `RecordEndTime`
- `PlayURL`
- `CmdURL`

`PlayURL` is used to download the original broadcast recording.

`CmdURL` is used to delete the DVR copy after a successful archive.

No video transcoding is performed. The original HDHomeRun recording is copied as-is.

## Important notes

### Existing destination files

If the destination file already exists, the script skips that recording and **does not delete the HDHomeRun source**.

This prevents an existing, incomplete, or unrelated file from accidentally causing the source recording to be deleted.

### Recordings still in progress

The script compares `RecordEndTime` against the current time and waits an additional configurable buffer before processing the recording.

Default:

```text
90 seconds
```

Override it with:

```powershell
-CompletionBufferSeconds 180
```

### Network interruption during a copy

Downloads are first written with a `.partial` extension.

For example:

```text
Show Name - S01E01.mpg.partial
```

Only after the download succeeds is the file renamed to `.mpg`.

If the transfer fails, the partial file is removed and the original HDHomeRun recording remains untouched.

## Example setup with Emby

A common layout is:

```text
HDHomeRun FLEX
    |
    | records OTA television
    v
USB DVR storage
    |
    | PowerShell sync
    v
\\MediaServer\Media\TV
    |
    v
Emby library
```

The HDHomeRun USB drive acts as temporary storage, while the Emby server becomes the long-term archive.
