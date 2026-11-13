# AI Sound Design Installer

One app that installs and updates AI Sound Design: on a Mac with Apple Silicon (M1 or
later, macOS 14 or newer) and on a Windows PC (Windows 10 or 11, 64-bit, an NVIDIA GPU).
Its window offers, each with a checkbox:

| Part | From | What the installer does |
|---|---|---|
| Backend services | [ai-services](https://github.com/ai-sound-design/ai-services), `main` | Mac: runs its `install_mac.sh` (Homebrew, Python, PostgreSQL, Ollama, the models, background services). Windows: in Docker Desktop with its `install.ps1`, or on the PC directly with its `install_windows.ps1` (Python, PostgreSQL, Ollama, the models, background services) |
| Web UI | [ai-sound-webui](https://github.com/ai-sound-design/ai-sound-webui), `main` | set up with the services, opened by the app **AI Sound Design** (Mac) or from the Start menu (Windows); on Windows also as a container beside the Docker stack |
| Pro Tools plugin | the newest release of [ai-protools-aax](https://github.com/ai-sound-design/ai-protools-aax/releases) | installs its macOS `.pkg` or its Windows setup |
| Sound database | the BBC Sound Effects archive | loads its index through the services' setup step; optionally all of its audio (60 GB) and the audio index |

On Windows the window also asks where the backend and the web UI run, in Docker Desktop
(when it is installed) or on the PC directly, and whether the vision-language model for
the spotting runs in the stack's own Ollama container or in an Ollama installed on the PC
(found when it is there already, installed otherwise).

Opened again, it shows what is installed and compares it with GitHub: the commit of the
services and of the web UI with their `main`, the plugin with its newest release, and
itself with the newest release here. What has an update is ticked; a newer installer
offers to replace itself and opens again.

## For users

### Mac

1. Download **AI-Sound-Design-Installer-macOS.zip** from the
   [newest release](https://github.com/ai-sound-design/installer/releases/latest)
   and open it (Safari unpacks it into Downloads).
2. Double-click **AI Sound Design Installer**. The app is not signed by Apple, so the first
   time macOS says it could not verify it: click *Done*, open *System Settings > Privacy &
   Security*, click **Open Anyway** and confirm with the Mac's password.
3. Tick what you want, choose folders under *Folders* if the defaults do not suit, click
   **Install**. macOS asks for the Mac's password when Homebrew or the plugin is installed.

Afterwards `~/AI Sound Design` holds the installation and a copy of the installer for later
updates; the app **AI Sound Design** in Applications opens the web UI.

### Windows

1. Download **AI-Sound-Design-Installer-Windows.zip** from the
   [newest release](https://github.com/ai-sound-design/installer/releases/latest), right-click
   it, *Extract All*.
2. Double-click **AI Sound Design Installer.exe** in the unpacked folder (keep
   `install-components.ps1` beside it). The app is not signed, so Windows SmartScreen may say
   it protected the PC: click *More info*, then **Run anyway**.
3. Tick what you want, choose where the backend runs, choose folders under *Folders* if the
   defaults do not suit, click **Install**. Windows asks for permission when the plugin's setup
   or Node.js is installed.

The backend in Docker Desktop needs [Docker Desktop](https://docs.docker.com/desktop/setup/install/windows-install/)
installed and started once; on the PC directly it needs nothing installed beforehand (the
installer fetches Python, PostgreSQL, ffmpeg, Ollama and Node.js). Either way the NVIDIA
driver must be current.

Afterwards `%UserProfile%\AI Sound Design` holds the installation and a copy of the
installer for later updates; the Start menu folder **AI Sound Design** has the installer, the
web UI and the setup page.

### Both

The first installation downloads about 25 GB (models included) and takes 30 to 60
minutes. The sound database loads in the background: the window can be closed while it
does, the loading carries on after a restart, and opening the installer again shows where
it is. What went on is also in `installer.log` next to the installation.

## How it works

| File | |
|---|---|
| `macos/Installer.swift` | the Mac app (SwiftUI): the choice, the update check, the progress, the self-update |
| `macos/install-components.sh` | the work on a Mac, in the app's Resources: fetches and installs the chosen parts; prints `@@` lines the app reads (steps, status, progress, errors) |
| `macos/askpass.sh` | the password dialog `sudo` uses when Homebrew is installed (`SUDO_ASKPASS`) |
| `macos/make-icon.swift`, `macos/build.sh` | the icon; builds the app and the ZIP |
| `windows/Installer.csproj`, `Model.cs`, `MainWindow.xaml(.cs)` | the Windows app (WPF on .NET Framework 4.8, which Windows 10 and 11 already have): the same window and checks |
| `windows/install-components.ps1` | the work on Windows, beside the `.exe`: the same steps and `@@` lines |
| `windows/make-icon.ps1`, `windows/build.ps1` | the icon; builds the app and the ZIP (needs the .NET SDK) |
| `VERSION` | the installer's version |

Both worker scripts also run without the app:

```bash
AISD_COMPONENTS="backend webui plugin database" bash macos/install-components.sh
```

```powershell
$env:AISD_COMPONENTS = "backend webui plugin database"
$env:AISD_BACKEND_MODE = "docker"     # or local; AISD_WEBUI_MODE likewise, AISD_OLLAMA docker|host
powershell -ExecutionPolicy Bypass -File windows\install-components.ps1
```

`AISD_SOURCE_DIR=<ai-services checkout>` installs that checkout instead of fetching `main`
(for development; the installer then reports *Local changes* instead of comparing). The
repositories can be pointed elsewhere with `AISD_SERVICES_REPO`, `AISD_WEBUI_REPO`,
`AISD_PLUGIN_REPO` and `AISD_INSTALLER_REPO`; `AISD_HOME` moves the installation folder.

## Releasing a new version

Only needed when something in `macos/` or `windows/` changes; new versions of the
services, the web UI or the plugin reach users without a new installer.

1. Raise the version in `VERSION` and commit.
2. Push a tag with that version, from any computer:

   ```bash
   git tag v1.0.1
   git push origin v1.0.1
   ```

GitHub then builds the Mac app on a Mac and the Windows app on a Windows machine
(`.github/workflows/release.yml`), builds pgvector for PostgreSQL 17 on Windows (what the
backend on Windows without Docker fetches, since pgvector publishes no Windows binaries),
creates the release and attaches `AI-Sound-Design-Installer-macOS.zip`,
`AI-Sound-Design-Installer-Windows.zip` and `pgvector-pg17-windows-x64.zip`. Installed
installers find the release the next time they are opened and offer to update themselves.

To build locally: on a Mac with Apple's command line tools `bash macos/build.sh` (the
result in `macos/build/`); on Windows with the .NET SDK
`powershell -ExecutionPolicy Bypass -File windows\build.ps1` (the result in `windows\build\`).
