# HDHomeRun Recording Sync

Scripts that automatically move completed recordings from an HDHomeRun FLEX DVR to another storage location, such as an Emby TV library, NAS, media server, or local disk.

Three platforms are supported:

| Platform | Script | Scheduler |
|---|---|---|
| Windows | `HDHomeRunRecordingsSync.ps1` | Task Scheduler |
| macOS | `hdhomerun-recordings-sync.sh` | launchd |
| Linux | `hdhomerun-recordings-sync.sh` | systemd timer |

macOS and Linux share one script. It detects the platform at startup and
adjusts the two commands whose options differ between BSD and GNU userland
(`stat` and `date`); everything else is identical.

All implementations follow the same logic and safety rules. Everything
described below applies to all of them unless a section is marked otherwise.

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

Common to both platforms:

- An HDHomeRun model with DVR storage available through `recorded_files.json`
- A writable destination folder
- The computer and HDHomeRun must be able to reach each other over the network

### Windows

- Windows with Windows PowerShell or PowerShell
- `curl.exe` available in PATH
  - Included with current versions of Windows 10 and Windows 11

### macOS

- `bash` — the script targets bash 3.2, so the version macOS ships is sufficient and Homebrew bash is not required
- `curl` — included with macOS
- `jq` — included with macOS 15 (Sequoia) and later at `/usr/bin/jq`

On older macOS versions, install `jq` with Homebrew:

```bash
brew install jq
```

### Linux

- `bash`
- `curl`
- `jq`

Install the dependencies for your distribution:

```bash
sudo apt install curl jq          # Debian, Ubuntu, Raspberry Pi OS
sudo dnf install curl jq          # Fedora, RHEL, Rocky, Alma
sudo pacman -S curl jq            # Arch
sudo zypper install curl jq       # openSUSE
```

### Checking dependencies

On either platform:

```bash
command -v bash curl jq
```

## Configuration

Both scripts accept the same three settings.

Windows, as PowerShell parameters:

```powershell
param(
    [string]$HdHomeRun = "http://hdhomerun.local",
    [string]$DestinationRoot = "D:\Media\TV",
    [int]$CompletionBufferSeconds = 90
)
```

macOS, as command-line options:

```bash
--hdhomerun "http://hdhomerun.local"   # HDHomeRun base URL
--dest      "$HOME/Media/TV"           # Destination root
--buffer    90                         # Completion buffer, seconds
```

The defaults differ only in the destination, which follows each platform's
conventions.

### HDHomeRun address

By default the script uses:

```text
http://hdhomerun.local
```

If name resolution does not work on your network, use the HDHomeRun's IP address instead:

```powershell
-HdHomeRun "http://192.168.1.50"
```

```bash
--hdhomerun "http://192.168.1.50"
```

A static DHCP reservation is recommended if you use an IP address.

On macOS you can confirm the HDHomeRun is reachable with:

```bash
curl -fsS http://hdhomerun.local/discover.json
```

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

On macOS the default destination is:

```text
$HOME/Media/TV
```

Override it with:

```bash
--dest "/Volumes/Media/TV"
```

The same caveat applies: an SMB share mounted in Finder belongs to your login
session and is not visible to a LaunchDaemon running as root.

## Running manually (Windows)

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

## Running manually (macOS and Linux)

Make the script executable once:

```bash
chmod +x hdhomerun-recordings-sync.sh
```

The Unix script takes the same three settings as command-line options:

| Option | Default | Equivalent PowerShell parameter |
|---|---|---|
| `--hdhomerun URL` | `http://hdhomerun.local` | `-HdHomeRun` |
| `--dest PATH` | `$HOME/Media/TV` | `-DestinationRoot` |
| `--buffer SECONDS` | `90` | `-CompletionBufferSeconds` |
| `--dry-run` | off | *(no equivalent)* |

Example:

```bash
./hdhomerun-recordings-sync.sh \
  --hdhomerun "http://192.168.1.50" \
  --dest "/Volumes/Media/TV"
```

If the defaults already match your setup:

```bash
./hdhomerun-recordings-sync.sh
```

### Dry run

The Unix script adds a `--dry-run` flag that has no PowerShell equivalent. It
reports every destination path it would write and every recording it would
delete, without copying or deleting anything:

```bash
./hdhomerun-recordings-sync.sh --dest "/Volumes/Media/TV" --dry-run
```

Running this once before the first real sync is recommended. It confirms the
HDHomeRun is reachable, the destination is writable, and the generated folder
and filename layout is what you expect.

### Destination paths

On macOS, external drives and network shares appear under `/Volumes`:

```bash
--dest "/Volumes/Media/TV"
```

For an SMB share, mount it in Finder first (**Go → Connect to Server**, then
`smb://nas.local/Media`).

On Linux, mount points are conventionally under `/mnt` or `/media`:

```bash
--dest "/mnt/media/TV"
```

A network share should be listed in `/etc/fstab` so it is mounted at boot
rather than by a desktop session. On either platform, a share that is not
mounted when the script runs is treated as an offline destination, so nothing
is copied or deleted.

### Filenames and time zones

Date-based filenames are generated in the machine's **local** time, matching
the Windows script's behavior. A recording that airs late in the evening will
therefore produce a different filename on a machine set to UTC than on one set
to your local zone. If two machines sync the same library, give them the same
time zone setting.

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

Logs are stored relative to the script.

Windows:

```text
logs\hdhomerun-archive.log
```

macOS and Linux:

```text
logs/hdhomerun-archive.log
```

Follow the log live with:

```bash
tail -f logs/hdhomerun-archive.log
```

On Linux, output from scheduled runs is additionally captured by the journal:

```bash
journalctl --user -u hdhomerun-sync.service -f
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

## Run automatically every 15 minutes (Windows)

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

## Run automatically every 15 minutes (macOS)

macOS uses **launchd** rather than cron. A LaunchAgent is the closest
equivalent to a Task Scheduler task.

### General

Create the file:

```text
~/Library/LaunchAgents/local.hdhomerun-sync.plist
```

The `Label` inside the file must match the filename, or the job will fail to
load. launchd job labels share a single flat, machine-wide namespace, so the
reverse-DNS style shown here is the convention for avoiding collisions. The
`local.` prefix claims no domain; if you own one, `tech.example.hdhomerun-sync`
is equally valid. The label is also how you address the job in every
`launchctl` command below.

Create the log directory first — launchd opens its log files *before* running
the script, and the job fails to start if the directory does not yet exist:

```bash
mkdir -p ~/Scripts/logs
```

### The job definition

Replace `YOURNAME` and the two paths to match your setup:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.hdhomerun-sync</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/YOURNAME/Scripts/hdhomerun-recordings-sync.sh</string>
        <string>--hdhomerun</string>
        <string>http://hdhomerun.local</string>
        <string>--dest</string>
        <string>/Volumes/Media/TV</string>
    </array>

    <key>StartInterval</key>
    <integer>900</integer>

    <key>RunAtLoad</key>
    <false/>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin</string>
    </dict>

    <key>StandardOutPath</key>
    <string>/Users/YOURNAME/Scripts/logs/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/YOURNAME/Scripts/logs/launchd.err.log</string>
</dict>
</plist>
```

Each argument must be its own `<string>` element. Unlike Task Scheduler's
single **Arguments** field, launchd does not split a string on spaces, so a
destination containing spaces needs no quoting here.

`StartInterval` is expressed in seconds, so 15 minutes is `900`.

The explicit `PATH` matters because launchd does **not** read your shell
profile. A job inherits a minimal environment, so a `jq` installed by Homebrew
into `/opt/homebrew/bin` would otherwise not be found. The script reports this
clearly if it happens:

```text
FATAL: Required tool 'jq' not found in PATH.
```

### Loading the job

Check the file parses, then load and start it:

```bash
plutil -lint ~/Library/LaunchAgents/local.hdhomerun-sync.plist

launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.hdhomerun-sync.plist
launchctl enable  gui/$(id -u)/local.hdhomerun-sync
```

Because `RunAtLoad` is `false`, the first run happens 15 minutes later. Trigger
one immediately to confirm it works:

```bash
launchctl kickstart gui/$(id -u)/local.hdhomerun-sync
```

Then watch the result:

```bash
tail -f ~/Scripts/logs/hdhomerun-archive.log
```

### Checking status

```bash
launchctl print gui/$(id -u)/local.hdhomerun-sync
```

The `last exit code` field in that output is the quickest way to confirm the
job is running cleanly.

### Editing or removing the job

launchd caches the job definition, so **any edit to the plist requires an
unload and reload** — saving the file alone changes nothing:

```bash
launchctl bootout gui/$(id -u)/local.hdhomerun-sync
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.hdhomerun-sync.plist
```

To remove it permanently, `bootout` it and delete the plist.

### Prevent overlapping copies

No configuration is needed. launchd will not start a second instance of a job
that is still running, which is the equivalent of Task Scheduler's:

```text
If the task is already running:
Do not start a new instance
```

As a second layer, the script takes its own lock in `logs/.sync.lock` and exits
early if another run holds it. This also covers a manual run overlapping a
scheduled one:

```text
SKIP: Another sync is already running (pid 4812).
```

A lock left behind by a killed process is detected and reclaimed automatically.

### Sleep and missed runs

A LaunchAgent runs only while you are logged in, and a sleeping Mac runs
nothing. When the machine wakes, launchd runs a missed `StartInterval` job once
— it does not replay every interval that elapsed. This is the practical
equivalent of Task Scheduler's:

```text
Run task as soon as possible after a scheduled start is missed
```

For a Mac that should archive around the clock, either disable sleep for the
machine, or install the job as a **LaunchDaemon** in `/Library/LaunchDaemons`
instead. A daemon runs as root at boot without anyone logged in, which is the
counterpart to the Windows "Run only when user is logged on" trade-off. Note
that a daemon cannot see SMB shares you mounted in Finder, since those belong
to your login session — the same caveat as mapped drive letters on Windows.

### If the destination is an external or network volume

macOS may block a background job from reading removable or network volumes
until it is granted permission. If the script logs `OFFLINE` for a destination
that you can browse normally in Finder, grant Full Disk Access to `/bin/bash`
under **System Settings → Privacy & Security → Full Disk Access**.

## Run automatically every 15 minutes (Linux)

Most distributions use **systemd**, which splits the job into two units: a
`.service` describing what to run, and a `.timer` describing when. This is the
closest equivalent to a Task Scheduler task or a launchd job.

A cron alternative is described at the end of this section.

### The service unit

Create `~/.config/systemd/user/hdhomerun-sync.service`, replacing the path and
destination with your own:

```ini
[Unit]
Description=HDHomeRun recording sync
Wants=network-online.target
After=network-online.target
RequiresMountsFor=/mnt/media

[Service]
Type=oneshot
ExecStart=/home/YOURNAME/scripts/hdhomerun-recordings-sync.sh --hdhomerun http://hdhomerun.local --dest /mnt/media/TV
```

`Type=oneshot` tells systemd the unit runs to completion rather than staying
resident, which is what a periodic sync does.

`RequiresMountsFor=` is worth setting when the destination is a network share
or external disk. systemd will not start the job until that path is actually
mounted, which avoids a run that would only log `OFFLINE` and exit.

Unlike launchd, arguments are written as a normal command line here, so a
destination containing spaces needs quoting.

### The timer unit

Create `~/.config/systemd/user/hdhomerun-sync.timer`:

```ini
[Unit]
Description=Run HDHomeRun recording sync every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Persistent=true
Unit=hdhomerun-sync.service

[Install]
WantedBy=timers.target
```

`OnUnitActiveSec=15min` measures from the end of the previous run, so a long
copy never causes runs to stack up.

`Persistent=true` runs the job once after a missed window — for example when
the machine was powered off. It is the equivalent of Task Scheduler's **Run
task as soon as possible after a scheduled start is missed**.

### Enabling the timer

```bash
systemctl --user daemon-reload
systemctl --user enable --now hdhomerun-sync.timer
```

Run the sync once immediately to confirm it works, without waiting for the
timer:

```bash
systemctl --user start hdhomerun-sync.service
```

### Checking status

```bash
systemctl --user list-timers hdhomerun-sync.timer
systemctl --user status hdhomerun-sync.service
```

Script output is captured by the journal in addition to the script's own log
file:

```bash
journalctl --user -u hdhomerun-sync.service -f
```

### Editing or removing the units

systemd caches unit files, so **any edit requires a `daemon-reload`**:

```bash
systemctl --user daemon-reload
systemctl --user restart hdhomerun-sync.timer
```

To remove it:

```bash
systemctl --user disable --now hdhomerun-sync.timer
rm ~/.config/systemd/user/hdhomerun-sync.{service,timer}
systemctl --user daemon-reload
```

### Prevent overlapping copies

No configuration is needed. systemd will not start a second instance of a
service that is still running, and the timer simply skips that window. This is
the equivalent of Task Scheduler's:

```text
If the task is already running:
Do not start a new instance
```

The script's own lock in `logs/.sync.lock` provides the same second layer as on
macOS, covering a manual run that overlaps a scheduled one.

### Running without a logged-in session

A user unit stops when your session ends. For a headless server or NAS that
should archive continuously, enable lingering so your user's units run from
boot:

```bash
sudo loginctl enable-linger YOURNAME
```

Alternatively, install the units system-wide in `/etc/systemd/system/` and add
a `User=` line to the `[Service]` section. Drop `--user` from every command
above. This is the same trade-off as a launchd LaunchDaemon on macOS, or
Windows' "Run only when user is logged on" — and it carries the same caveat
that a share mounted by your desktop session will not be visible to a
system-wide unit.

### Using cron instead

If you prefer cron, or are on a system without systemd, run `crontab -e` and
add:

```cron
*/15 * * * * /home/YOURNAME/scripts/hdhomerun-recordings-sync.sh --dest /mnt/media/TV >/dev/null 2>&1
```

Two caveats apply. cron does not read your shell profile, so if `jq` lives
somewhere outside cron's minimal `PATH`, set it at the top of the crontab:

```cron
PATH=/usr/local/bin:/usr/bin:/bin
```

And cron has no concept of a job already running, so overlap protection rests
entirely on the script's own lock file. The script handles this correctly, but
systemd is the better choice where it is available.

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
