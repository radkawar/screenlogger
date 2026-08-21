# Installation

## Install the DMG

Screenlogger requires macOS 14 or later.

1. Download the DMG and its `.sha256` file from GitHub Releases.
2. Verify the checksum if desired:

   ```sh
   shasum -a 256 -c Screenlogger-latest-macos-universal.dmg.sha256
   ```

3. Open the DMG.
4. Drag Screenlogger to Applications.
5. Open the installed copy from Applications. Do not run the copy inside the
   mounted DMG.

Public release builds are Developer ID signed, notarized by Apple, and carry a
stapled ticket for offline Gatekeeper validation.

## First run

Screenlogger needs two macOS permissions before capture can start:

- Screen Recording lets Screenlogger capture pixels from the display.
- Accessibility lets Screenlogger identify the active application, browser
  website, and interface context needed for accurate exclusions.

Setup requests each permission once. If permission is still missing, the action
opens the correct System Settings pane instead of requesting it repeatedly.
Screen Recording changes can require quitting and reopening Screenlogger.

Granting permission does not start capture. Choose Start Capture after both
permissions are ready.

## Terminal command

Open Screenlogger Settings and use Integrations to install the `screenlog`
command. The default destination is `~/.local/bin`. Add that directory to the
shell path if needed.

## Build and install from source

Full Xcode is required.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
Scripts/install.sh
```

The source installer places the app in `~/Applications` and the CLI in
`~/.local/bin`.

## Remove Screenlogger

Removing the app does not delete the Library. The source checkout also provides:

```sh
Scripts/uninstall.sh
Scripts/uninstall.sh --purge-data --purge-skills
```

`--purge-data` permanently removes captured history. Review the command output
before confirming that option.
