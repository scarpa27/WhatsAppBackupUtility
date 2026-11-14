---
name: whatsapp-backup-manager
description: Safely create, inspect, verify, organize, and restore Android WhatsApp local backups using WhatsAppBackup.ps1 and ADB on Windows PowerShell.
---

# WhatsApp Backup Manager Skill

Use this skill when helping operate the local `WhatsAppBackup.ps1` utility for Android WhatsApp backups, recovery points, media synchronization, or migration to a new phone.

## Core model

Treat every saved state as a **recovery point**. Do not distinguish technically between an "archive" and a "migration"; both are recovery points containing a database/config snapshot and a reference to one shared Media archive.

Expected layout:

```text
<root>\
├── WhatsAppBackup.ps1
├── config.json
├── recovery-points\
│   └── <yyyy-MM-dd_HHmm>\
│       ├── Backups\
│       ├── Databases\
│       ├── recovery.json
│       ├── media-manifest.tsv   # only for recovery points captured by the utility
│       └── Media -> junction to shared\Media
├── shared\
│   └── Media\
├── logs\
└── tools\platform-tools\adb.exe
```

## Safety invariants

Never:

- overwrite or delete a protected recovery point;
- delete WhatsApp backup files from the source phone during backup creation;
- assume a cloud backup is fresher than the local `msgstore.db.crypt14`;
- accept a database older than the configured freshness limit without requiring the user to create a new WhatsApp backup;
- overwrite `msgstore.db.crypt14` while WhatsApp is actively restoring;
- factory-reset, trade in, or wipe the old phone before the destination phone is fully verified;
- treat shared Media as a mirror that should delete files missing from the phone;
- invent a recovery point timestamp: derive it from `msgstore.db.crypt14`.

Always:

- check the connected ADB device before operations;
- inspect the full local database timestamp and size;
- force-stop WhatsApp before taking the final filesystem snapshot;
- SHA-256 hash the recovery point's `msgstore.db.crypt14`;
- maintain only one physical shared Media archive;
- store a point-in-time Media manifest for newly created recovery points;
- verify the selected recovery point before restore preparation;
- explicitly place the selected `msgstore.db.crypt14` during restore preparation;
- stop file-copy operations once WhatsApp begins its own restore process.

## Freshness workflow

The configured default maximum age is 12 hours.

If the phone's:

```text
/sdcard/Android/media/com.whatsapp/WhatsApp/Databases/msgstore.db.crypt14
```

is older than the limit, instruct the user to open:

```text
WhatsApp -> Settings -> Chats -> Chat backup -> Back up
```

Wait for completion and re-check the filesystem timestamp. Do not proceed merely because the user pressed Enter; verify that the database is now fresh.

## Backup workflow

Preferred command:

```powershell
.\WhatsAppBackup.ps1 backup
```

Expected behavior:

1. Identify exactly one authorized ADB device.
2. Validate backup freshness.
3. Force-stop WhatsApp.
4. Re-check the full database.
5. Create a timestamp-derived recovery point.
6. Pull `Backups` and `Databases` using `adb pull -a`.
7. Verify main database size and hash it.
8. Keep the current full database plus at most one fallback dated/incremental chain.
9. Synchronize the shared Media repository.
10. Write metadata and manifest.
11. Create a Media junction.

## Media strategy

The shared Media repository is an archival superset.

For subsequent backups, avoid retransferring the full Media tree. Build a phone manifest and local inventory and compare by:

```text
relative path + file size
```

Pull only missing or size-changed files for ordinary small change sets. Do not delete archived-only files.

The current ADB CLI supports `pull -a` to preserve timestamps/mode and `push --sync` to skip host files that do not need to be pushed. Do not use `push -a`; `-a` is a pull option in current ADB.

## Restore workflow

Preferred command:

```powershell
.\WhatsAppBackup.ps1 restore-prep -RecoveryPoint <id>
```

Before invoking it:

- WhatsApp should be installed on the destination phone;
- it may be opened only enough to initialize its shared-storage structure;
- it must not already be actively restoring.

Restore preparation should:

1. Verify the recovery point.
2. Show the destination device identity.
3. Require explicit typed confirmation.
4. Force-stop WhatsApp.
5. Create remote `Backups`, `Databases`, and `Media` directories.
6. `adb push --sync` Backups.
7. Push the selected full `msgstore.db.crypt14` explicitly to the exact destination filename.
8. `adb push --sync` shared Media.
9. Verify the remote database size.
10. Tell the user to open WhatsApp and select the local restore.

Once WhatsApp begins restoration, do not push the database again unless deliberately restarting the entire restore attempt.

## Legacy organization

If the old layout contains:

```text
archives\<name>\WhatsApp
migrations\<name>\WhatsApp
shared\Media
```

run:

```powershell
.\WhatsAppBackup.ps1 organize
```

The utility should move the old WhatsApp snapshots into `recovery-points` using the full database timestamp as the recovery point ID, preserve shared Media, recreate/retain junctions, and mark old rescue/archive points protected.

Do not fabricate historical `media-manifest.tsv` files for legacy points: the current shared Media repository may contain files added after those snapshots. If the source phone still holds the same current full database as an imported point, running `backup` should enrich that existing point with a real phone-derived Media manifest rather than create a duplicate.

## Cleanup policy

Cleanup is optional and conservative.

Protected points are never modified by cleanup. For ordinary recovery points, keep:

- `msgstore.db.crypt14`;
- the newest dated full database as fallback;
- increments associated with that fallback chain.

Delete only older dated/incremental chains from the PC copy. Do not clean the source phone as part of this workflow.

## Important historical context

The workflow exists because a WhatsApp bulk-deletion event once removed a long-running chat, while a fresh local `msgstore.db.crypt14` successfully restored nearly a decade of conversation with only a short rollback window. Therefore local full database preservation, timestamp checking, external copies, and non-destructive behavior take priority over convenience.
