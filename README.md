# AI Sound Design Installer

One app that installs and updates AI Sound Design on a Mac with Apple Silicon (M1 or
later, macOS 14 or newer). Its window offers, each with a checkbox:

| Part | From | What the installer does |
|---|---|---|
| Backend services | [ai-services](https://github.com/ai-sound-design/ai-services), `main` | runs its `install_mac.sh`: Homebrew, Python, PostgreSQL, Ollama, the models, background services |
| Web UI | [ai-sound-webui](https://github.com/ai-sound-design/ai-sound-webui), `main` | set up with the services, opened by the app **AI Sound Design** |
| Pro Tools plugin | the newest release of [ai-protools-aax](https://github.com/ai-sound-design/ai-protools-aax/releases) | installs its macOS `.pkg` |
| Sound database | the BBC Sound Effects archive | loads its index through the services' setup step; optionally all of its audio (60 GB) and the audio index |

Opened again, it shows what is installed and compares it with GitHub: the commit of the
services and of the web UI with their `main`, the plugin with its newest release, and
itself with the newest release here. What has an update is ticked; a newer installer
offers to replace itself and opens again.

## For users

1. Download **AI-Sound-Design-Installer-macOS.zip** from the
   [newest release](https://github.com/ai-sound-design/installer/releases/latest)
   and open it (Safari unpacks it into Downloads).
2. Double-click **AI Sound Design Installer**. The app is not signed by Apple, so the first
   time macOS says it could not verify it: click *Done*, open *System Settings > Privacy &
   Security*, click **Open Anyway** and confirm with the Mac's password.
3. Tick what you want, choose folders under *Folders* if the defaults do not suit, click
   **Install**. macOS asks for the Mac's password when Homebrew or the plugin is installed.

The first installation downloads about 25 GB (models included) and takes 30 to 60
minutes. Afterwards `~/AI Sound Design` holds the installation and a copy of the installer
for later updates; the app **AI Sound Design** in Applications opens the web UI.

The sound database loads in the background: the window can be closed while it does, the
loading carries on after a restart, and opening the installer again shows where it is.
What went on is also in `~/AI Sound Design/installer.log`.

## How it works

| File | |
|---|---|
| `macos/Installer.swift` | the app (SwiftUI): the choice, the update check, the progress, the self-update |
| `macos/install-components.sh` | the work, in the app's Resources: fetches and installs the chosen parts; prints `@@` lines the app reads (steps, status, progress, errors) |
| `macos/askpass.sh` | the password dialog `sudo` uses when Homebrew is installed (`SUDO_ASKPASS`) |
| `macos/make-icon.swift` | draws the icon |
| `macos/build.sh` | builds the app and the ZIP |
| `VERSION` | the installer's version |

`install-components.sh` also runs without the app:

```bash
AISD_COMPONENTS="backend webui plugin database" bash macos/install-components.sh
```

`AISD_SOURCE_DIR=<ai-services checkout>` installs that checkout instead of fetching `main`
(for development; the installer then reports *Local changes* instead of comparing). The
repositories can be pointed elsewhere with `AISD_SERVICES_REPO`, `AISD_WEBUI_REPO`,
`AISD_PLUGIN_REPO` and `AISD_INSTALLER_REPO`.

## Releasing a new version

Only needed when something in `macos/` changes; new versions of the services, the web UI
or the plugin reach users without a new installer.

1. Raise the version in `VERSION` and commit.
2. Push a tag with that version, from any computer:

   ```bash
   git tag v1.0.1
   git push origin v1.0.1
   ```

GitHub then builds the app on a Mac (`.github/workflows/release-macos.yml`), creates the
release and attaches `AI-Sound-Design-Installer-macOS.zip`. Installed installers find it the
next time they are opened and offer to update themselves.

To build locally on a Mac with Apple's command line tools: `bash macos/build.sh` (the
result is in `macos/build/`).
