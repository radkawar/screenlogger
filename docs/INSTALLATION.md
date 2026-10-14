# Installation

## Install the DMG

Screenlogger requires macOS 14 or later.
The app and CLI are universal (Apple silicon and Intel). Optional Meaning
search requires Apple silicon running the native arm64 app; Exact search
does not require the semantic worker or model downloads.

Meaning search is off until you approve model downloads and enable it in
Settings > Search. Model weights are not bundled with the installer.

1. Download the DMG and its `.sha256` file from GitHub Releases.
2. If necessary, verify the checksum:

   ```sh
   shasum -a 256 -c Screenlogger-latest-macos-universal.dmg.sha256
   ```

3. Open the DMG.
4. Drag Screenlogger to Applications.
5. Open the installed copy from Applications. Do not run the copy inside the
   mounted DMG.

Public releases use Developer ID signatures and Apple notarization.
Their stapled tickets let Gatekeeper check them without a network connection.

When a new build starts, Screenlogger updates an existing `screenlog` command
if its installation receipt identifies it as Screenlogger content.
It also updates existing assistant skills that Screenlogger owns.
It does not install tools that you never enabled.
It does not replace unrelated files.

Before upgrading to v0.2, [back up your Library](BACKUP_AND_RESTORE.md).
The app applies transactional schema updates and resumes local payload
migration automatically. Keep the backup if you may need to return to an
older app version; backward compatibility of the migrated Library is not
guaranteed. Upgrading does not itself opt you into model downloads.

## First run

Screenlogger needs two macOS permissions before capture can start:

- Screen Recording permits Screenlogger to capture display pixels.
- Accessibility supplies the active application, browser website, and interface
  context that exclusions require.

Setup requests each permission once. If permission is still missing, the action
opens the correct System Settings pane. It does not repeat the request.
Screen Recording changes can require you to quit and reopen Screenlogger.

Permission does not start capture.
Choose Start Capture after both permissions are ready.

## Terminal command

Open Screenlogger Settings.
Use Integrations to install the `screenlog` command.
The default destination is `~/.local/bin`.
Add that directory to the shell path if necessary.

## Build and install from source

Full Xcode is required.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
Scripts/install.sh
```

The source installer places the app in `~/Applications` and the CLI in
`~/.local/bin`.

The source installer authenticates the app and managed command separately.
An app-managed command update can advance its own receipt without replacing
the app; the next source installation accepts that verified update. Modified
or unowned app, command, framework, and skill files are still preserved.

## Remove Screenlogger

App removal does not delete the Library. The source repository also provides:

```sh
Scripts/uninstall.sh
Scripts/uninstall.sh --purge-data --purge-skills
```

`--purge-data` permanently removes captured history.
Review the command output before you confirm that option.
