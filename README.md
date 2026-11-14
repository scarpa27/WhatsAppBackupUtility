# WhatsApp Backup Manager

A conservative PowerShell utility for Android WhatsApp local backups and phone migrations.

It is designed around the workflow that successfully recovered a long WhatsApp history from `msgstore.db.crypt14`: preserve a fresh full database, keep one shared Media archive, create timestamped recovery points, and never depend on a cloud backup being the freshest copy.

## Requirements

- Windows PowerShell 5.1 or newer
- Android phone with USB debugging enabled and authorized
- `adb.exe`, preferably at `tools\platform-tools\adb.exe`
- WhatsApp Android shared storage at:
  `/sdcard/Android/media/com.whatsapp/WhatsApp`

## Recommended layout

Place these files in your WhatsApp backup root, e.g. `C:\data\whatsapp-database`:

```text
C:\data\whatsapp-database\
├── WhatsAppBackup.ps1
├── config.json
├── recovery-points\
├── shared\
│   └── Media\
├── logs\
└── tools\
    └── platform-tools\
        └── adb.exe
```

The script can import the previous layout containing `archives\...\WhatsApp` and `migrations\...\WhatsApp` by running `organize`.

## First run with the current folder structure

Copy `WhatsAppBackup.ps1` and `config.json` to:

```text
C:\data\whatsapp-database
```

Then run:

```powershell
Set-Location C:\data\whatsapp-database
.\WhatsAppBackup.ps1 organize
```

This unifies legacy `archives` and `migrations` into `recovery-points`. It does not duplicate shared Media.

Then inspect:

```powershell
.\WhatsAppBackup.ps1 status
.\WhatsAppBackup.ps1 list
```

If the old/source phone is still connected and its current `msgstore.db.crypt14` is the same database already imported by `organize`, run:

```powershell
.\WhatsAppBackup.ps1 backup
```

The utility recognizes the existing recovery point by timestamp/size/SHA-256 and enriches it with a point-in-time Media manifest instead of creating a duplicate recovery point.

## Interactive program

```powershell
.\WhatsAppBackup.ps1
```

Menu actions:

1. Status
2. Create recovery point
3. List recovery points
4. Verify recovery point
5. Prepare restore to connected phone
6. Organize legacy archives/migrations
7. Cleanup a recovery point
8. Exit

## Create a new recovery point

```powershell
.\WhatsAppBackup.ps1 backup
```

The program:

1. Checks the connected ADB device.
2. Inspects `msgstore.db.crypt14` on the phone.
3. Rejects a database older than the configured freshness limit (12 hours by default).
4. If stale, tells you to run **WhatsApp -> Settings -> Chats -> Chat backup -> Back up**, then re-checks the file.
5. Force-stops WhatsApp before the final snapshot.
6. Pulls `Backups` and `Databases`.
7. SHA-256 hashes `msgstore.db.crypt14`.
8. Preserves the pulled database set unchanged.
9. Synchronizes one shared Media archive.
10. Writes `recovery.json` and `media-manifest.tsv`.
11. Creates a `Media` junction inside the recovery point pointing to the single shared Media repository.

Older dated/incremental chains are removed only by the explicit `cleanup` action.

## Media synchronization

The first run must pull the entire Media tree.

Later runs scan the Android Media tree and the local Media repository and compare:

```text
relative path + file size
```

Only missing or size-changed files are pulled when the change set is reasonably small. This avoids retransferring tens of gigabytes on every backup.

Files that exist locally but no longer exist on the phone are intentionally retained. The shared Media repository is an archival superset, not a mirror.

Every newly created recovery point stores a point-in-time `media-manifest.tsv`, allowing verification that all media known at that recovery point still exists in the shared repository.

## Verify

Interactive:

```powershell
.\WhatsAppBackup.ps1 verify
```

Or deep-verify all media paths/sizes recorded by the recovery point:

```powershell
.\WhatsAppBackup.ps1 verify -RecoveryPoint 2026-11-14_0648 -DeepVerify
```

## Restore preparation

Install WhatsApp on the destination phone and open it only enough to initialize the app. Do not begin a restore yet.

Then:

```powershell
.\WhatsAppBackup.ps1 restore-prep -RecoveryPoint 2026-11-14_0648
```

The script:

- verifies the recovery point;
- identifies the connected destination phone;
- force-stops WhatsApp;
- creates the shared-storage directories;
- syncs `Backups`;
- explicitly places the chosen `msgstore.db.crypt14`;
- uses `adb push --sync` for Media;
- if a Media manifest exists, verifies destination paths/sizes and explicitly repairs files skipped incorrectly by `--sync`;
- verifies the remote database size and SHA-256.

Afterward, open WhatsApp, verify the same number, confirm it detects the intended local backup, and choose **Restore**.

Once WhatsApp starts restoring, do **not** rerun `restore-prep` unless intentionally restarting the restore process.

## Cleanup

```powershell
.\WhatsAppBackup.ps1 cleanup
```

Cleanup is deliberately narrow. It only removes older dated/incremental database chains inside the selected PC recovery point, leaving:

- `msgstore.db.crypt14`
- the newest fallback dated full database
- increments belonging to that fallback chain
- Backups
- shared Media

Protected recovery points refuse cleanup.

## Configuration

`config.json` defaults:

```json
{
  "RootPath": ".",
  "RecoveryPointsDirectory": "recovery-points",
  "SharedMediaDirectory": "shared\\Media",
  "LogsDirectory": "logs",
  "ToolsDirectory": "tools",
  "RemoteWhatsAppPath": "/sdcard/Android/media/com.whatsapp/WhatsApp",
  "MaxBackupAgeHours": 12,
  "SelectivePullMaxFiles": 500,
  "KeepFallbackDatabaseChain": true,
  "ProtectedRecoveryPointIds": []
}
```

Add an irreplaceable recovery point ID to `ProtectedRecoveryPointIds` if you want cleanup protection in addition to its `recovery.json` metadata.

## Safety rules

- Do not reset the old phone until the new phone is fully verified.
- Do not delete the source phone's WhatsApp local backup files during backup creation.
- Do not assume the Google/Meta cloud backup is newer than `msgstore.db.crypt14`.
- Do not overwrite a recovery point just to refresh Media; Media is shared.
- Do not run restore file-copy operations while WhatsApp is actively restoring.
- Keep at least one known-good historical recovery point permanently.
