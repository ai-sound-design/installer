# What "AI Sound Design Installer.exe" runs (it sits beside it): installs or updates the
# parts chosen in its window. Part of github.com/ai-sound-design/installer.
# Also usable on its own:
#
#   $env:AISD_COMPONENTS = "backend webui plugin database"
#   powershell -ExecutionPolicy Bypass -File install-components.ps1
#
#   backend    ai-services (github.com/ai-sound-design/ai-services, main): in Docker Desktop,
#              set up by its install.ps1 (the images, the stack), or on Windows directly, set
#              up by its install_windows.ps1 (Python, PostgreSQL, Ollama, the models, the
#              background services); AISD_BACKEND_MODE=docker|local
#   webui      github.com/ai-sound-design/ai-sound-webui (main): as a container beside the
#              stack, or served on Windows by the services' installer; AISD_WEBUI_MODE
#   plugin     the newest release of github.com/ai-sound-design/ai-protools-aax (its setup)
#   database   the BBC Sound Effects index, through the setup service; "audio" with it also
#              downloads all of the archive's audio and builds the audio index
#
# AISD_OLLAMA: docker (the stack's own Ollama) or host (an Ollama installed on Windows,
# installed when missing); on Windows directly it is always the host's. AISD_DATA_DIR,
# AISD_SESSIONS_DIR, AISD_BBC_ARCHIVE, AISD_OWN_SOUNDS: the folders, passed on to the
# services' installer. AISD_SOURCE_DIR: a copy of ai-services to install instead of
# fetching main (a checkout under development).
#
# For the app it prints lines it reads: @@step <part> <running|done|failed|skipped>,
# @@status <text>, @@progress <0-100|->, @@error <text>. Everything else is the log.
# Run again, it updates what is there; every step only does what is missing, and the
# sound database carries on where it stopped.
#
# The commit of what was fetched goes into <folder>\.windows\installed-from, which the
# app compares with GitHub to offer an update.

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Env-Or($name, $default) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($value) { return $value } else { return $default }
}
$ServicesRepo = Env-Or "AISD_SERVICES_REPO" "ai-sound-design/ai-services"
$ServicesRef = Env-Or "AISD_SERVICES_REF" "main"
$WebuiRepo = Env-Or "AISD_WEBUI_REPO" "ai-sound-design/ai-sound-webui"
$WebuiRef = Env-Or "AISD_WEBUI_REF" "main"
$PluginRepo = Env-Or "AISD_PLUGIN_REPO" "ai-sound-design/ai-protools-aax"
$HomeDir = Env-Or "AISD_HOME" (Join-Path $env:UserProfile "AI Sound Design")
$Services = Join-Path $HomeDir "ai-services"
$Webui = Join-Path $HomeDir "ai-sound-webui"
$Components = @((Env-Or "AISD_COMPONENTS" "backend").Split(" ", [StringSplitOptions]::RemoveEmptyEntries))
$PluginKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{7C1E2B54-6D3A-4F0E-9B7B-AAX0A15D0001}_is1"
$PluginDir = Join-Path $env:CommonProgramFiles "Avid\Audio\Plug-Ins\AI Sound Design.aaxplugin"
$script:Temp = $null

function At($text) { Write-Output "@@$text" }
function Step($text) { Write-Output ""; Write-Output "== $text" }
function Ok($text) { Write-Output "   $text" }
function Cleanup { if ($script:Temp -and (Test-Path -LiteralPath $script:Temp)) { Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue }; $script:Temp = $null }
function Fail($message, $part) {
    At "error $message"
    if ($part) { At "step $part failed" }
    Cleanup
    exit 1
}
function Want($part) { return $Components -contains $part }
function TempDir {
    if (-not $script:Temp) {
        $script:Temp = Join-Path $env:TEMP ("ai-sound-design-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
        New-Item -ItemType Directory -Path $script:Temp | Out-Null
    }
    return $script:Temp
}

function Quote([string[]]$arguments) {
    # One command line for Start-Process: arguments with spaces in quotes
    return ($arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + $_.Replace('"', '\"') + '"' } else { $_ } }) -join " "
}
function Run($exe, [string[]]$arguments, $cwd = $null) {
    # A child whose output flows into this one's (the app shows it); its exit code is what counts
    $options = @{ FilePath = $exe; NoNewWindow = $true; Wait = $true; PassThru = $true }
    if ($arguments) { $options.ArgumentList = (Quote $arguments) }
    if ($cwd) { $options.WorkingDirectory = $cwd }
    $process = Start-Process @options
    return $process.ExitCode
}
function GitHub-Json($path) {
    try {
        return Invoke-RestMethod -Uri "https://api.github.com/repos/$path" -TimeoutSec 20 `
            -Headers @{ Accept = "application/vnd.github+json"; "User-Agent" = "ai-sound-design-installer" }
    } catch { return $null }
}
function Download($url, $file, $progress = $false) {
    # curl.exe comes with Windows 10; its progress bar (stderr, carriage returns) becomes the app's
    $arguments = @("-fL", "-A", "ai-sound-design-installer", "-o", $file, $url)
    if ($progress) { $arguments = @("--progress-bar") + $arguments } else { $arguments = @("-sS") + $arguments }
    return (Run "curl.exe" $arguments) -eq 0
}
function Read-Env($path) {
    $values = @{}
    if (Test-Path -LiteralPath $path) {
        foreach ($line in Get-Content -LiteralPath $path) {
            $trimmed = $line.Trim()
            if ($trimmed.StartsWith("#") -or -not $trimmed.Contains("=")) { continue }
            $key, $value = $trimmed.Split("=", 2)
            $values[$key.Trim()] = $value.Trim().Trim('"')
        }
    }
    return $values
}
function Set-EnvValue($path, $key, $value) {
    # Replace or append KEY=value; folders with forward slashes, which Compose takes on Windows
    $text = ""
    if (Test-Path -LiteralPath $path) { $text = [IO.File]::ReadAllText($path) }
    $line = "$key=$value"
    if ($text -match "(?m)^\s*$key\s*=") { $text = $text -replace "(?m)^\s*$key\s*=.*$", $line.Replace('$', '$$') }
    else { $text = $text.TrimEnd() + "`r`n$line`r`n" }
    [IO.File]::WriteAllText($path, $text.TrimStart(), (New-Object Text.UTF8Encoding $false))
}
function Record($folder, $values) {
    $dir = Join-Path $folder ".windows"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $lines = @($values.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
    [IO.File]::WriteAllLines((Join-Path $dir "installed-from"), $lines)
}
function Docker-Installed {
    return [bool](Get-Command docker -ErrorAction SilentlyContinue) -or (Test-Path (Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"))
}
function Installed-Backend { return (Test-Path -LiteralPath (Join-Path $Services ".env")) -and (Test-Path -LiteralPath (Join-Path $Services "docker-compose.yml")) }
function Installed-Mode($folder) {
    $record = Read-Env (Join-Path $folder ".windows\installed-from")
    return $record["mode"]
}
function Plugin-Version {
    # Installed by its setup: the version in the uninstall entry. Put there by hand: unknown ("?")
    try {
        $entry = Get-ItemProperty -Path $PluginKey -ErrorAction Stop
        if ($entry.DisplayVersion) { return ([string]$entry.DisplayVersion).TrimStart("v") }
    } catch { }
    if (Test-Path -LiteralPath (Join-Path $PluginDir "Contents\x64")) { return "?" }
    return $null
}
function Fetch-Repo($repo, $ref, $what, $part) {
    # The newest commit, then exactly that one: what is installed is known by its commit
    At "status Downloading $what from GitHub"
    $json = GitHub-Json "$repo/commits/$ref"
    if (-not $json -or -not $json.sha) { Fail "GitHub could not be reached. Is this PC online?" $part }
    $sha = [string]$json.sha
    $name = $repo.Split("/")[-1]
    $zip = Join-Path (TempDir) "$name.zip"
    if (-not (Download "https://codeload.github.com/$repo/zip/$sha" $zip)) { Fail "GitHub could not be reached. Is this PC online?" $part }
    $dir = Join-Path (TempDir) "$name-src"
    try { Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force } catch { Fail "The download is damaged; try again." $part }
    $source = Get-ChildItem -LiteralPath $dir -Directory | Select-Object -First 1
    if (-not $source) { Fail "The download is damaged; try again." $part }
    return @{ Source = $source.FullName; Commit = $sha }
}
function Install-Copy($source, $target, [string[]]$keep) {
    # Copied without what belongs to an installation, so an update keeps its settings, its
    # data and its environments; a file the new version dropped stays, unused.
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    $excluded = @()
    foreach ($folder in $keep) { $excluded += (Join-Path $source $folder); $excluded += (Join-Path $target $folder) }
    $arguments = @($source, $target, "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/NP", "/R:2", "/W:2", "/XF", ".env")
    if ($excluded) { $arguments += "/XD"; $arguments += $excluded }
    $code = Run "robocopy.exe" $arguments
    return $code -lt 8
}
function Project-Name {
    # The compose project of the services: COMPOSE_PROJECT_NAME in .env, else the name in docker-compose.yml
    $env = Read-Env (Join-Path $Services ".env")
    if ($env["COMPOSE_PROJECT_NAME"]) { return $env["COMPOSE_PROJECT_NAME"] }
    $compose = Join-Path $Services "docker-compose.yml"
    if ((Test-Path -LiteralPath $compose) -and ((Get-Content -LiteralPath $compose -Raw) -match "(?m)^name:\s*([A-Za-z0-9_-]+)")) { return $Matches[1] }
    return "ai-sound-services"
}
function Data-Dir {
    $env = Read-Env (Join-Path $Services ".env")
    $audio = $env["AUDIO_HOST_DIR"]
    if (-not $audio) { $audio = "./data/audio" }
    $data = Split-Path -Parent ($audio -replace "/", "\")
    if (-not [IO.Path]::IsPathRooted($data)) { $data = Join-Path $Services $data }
    return [IO.Path]::GetFullPath($data)
}

if (-not (Docker-Installed) -and -not (Env-Or "AISD_BACKEND_MODE" "")) { $BackendMode = "local" } else { $BackendMode = Env-Or "AISD_BACKEND_MODE" "docker" }
$WebuiMode = Env-Or "AISD_WEBUI_MODE" $BackendMode
$Ollama = Env-Or "AISD_OLLAMA" "docker"
if ($BackendMode -eq "local") { $Ollama = "host" }
if ((Want "audio") -and -not (Want "database")) { $Components += "database" }
# The web UI needs the services (their network, or their installer); the database needs them there
if (-not (Want "backend") -and ((Want "webui") -or (Want "database")) -and -not (Installed-Backend)) { $Components += "backend" }
if ((Installed-Backend) -and -not (Want "backend") -and (Installed-Mode $Services)) { $BackendMode = Installed-Mode $Services }

# ── Backend services ────────────────────────────────────────────────────────

if (Want "backend") {
    At "step backend running"
    $webuiWithIt = (Want "webui") -and ($WebuiMode -eq "local")
    if ($webuiWithIt) { At "step webui running" }
    $installer = if ($BackendMode -eq "docker") { "install.ps1" } else { "install_windows.ps1" }
    $modified = 0
    if ($env:AISD_SOURCE_DIR) {
        $source = $env:AISD_SOURCE_DIR
        if (-not (Test-Path -LiteralPath (Join-Path $source $installer))) { Fail "$source has no $installer." "backend" }
        Step "Backend services: from $source"
        $commit = ""
        if (Get-Command git -ErrorAction SilentlyContinue) {
            $commit = (& git -C $source rev-parse HEAD 2>$null | Out-String).Trim()
            if ((& git -C $source status --porcelain 2>$null | Out-String).Trim()) { $modified = 1 }
        }
        $origin = $source
    } else {
        Step "Backend services: fetching $ServicesRepo ($ServicesRef) from GitHub"
        $fetched = Fetch-Repo $ServicesRepo $ServicesRef "the backend services" "backend"
        $source = $fetched.Source
        $commit = $fetched.Commit
        $origin = $ServicesRepo
        if (-not (Test-Path -LiteralPath (Join-Path $source $installer))) { Fail "This version of ai-services ($ServicesRef) has no $installer yet." "backend" }
    }
    if ([IO.Path]::GetFullPath($source).TrimEnd("\") -ne [IO.Path]::GetFullPath($Services).TrimEnd("\")) {
        Ok "copying to $Services"
        if (-not (Install-Copy $source $Services @("data", ".windows", ".git"))) { Fail "Could not copy the backend services to $Services." "backend" }
    }
    $fresh = -not (Test-Path -LiteralPath (Join-Path $Services ".env"))
    $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $Services $installer), "-NoPrompt", "-NoBrowser")
    if ($env:AISD_DATA_DIR -and $fresh) { $arguments += @("-DataDir", $env:AISD_DATA_DIR) }
    if ($env:AISD_BBC_ARCHIVE) { $arguments += @("-BbcArchive", $env:AISD_BBC_ARCHIVE) }
    if ($env:AISD_OWN_SOUNDS) { $arguments += @("-OwnSounds", $env:AISD_OWN_SOUNDS) }
    if ($BackendMode -eq "docker") {
        $arguments += @("-Ollama", $Ollama)
    } else {
        if ($env:AISD_SESSIONS_DIR) { $arguments += @("-Sessions", $env:AISD_SESSIONS_DIR) }
        # The web UI: wanted, or there from before (kept and updated); else left out
        $webuiThere = Test-Path -LiteralPath (Join-Path $Webui "package.json")
        if ($webuiWithIt) { $arguments += @("-WebUI", "on") }
        elseif (-not $webuiThere -or ((Read-Env (Join-Path $Services ".env"))["WINDOWS_WEBUI"] -eq "0")) { $arguments += @("-WebUI", "off") }
    }
    $env:AISD_GUI = "1"
    $env:AISD_WEBUI_DIR = $Webui
    $code = Run "powershell.exe" $arguments $Services
    if ($code -ne 0) { Fail "The backend services could not be installed; the details say where it stopped." "backend" }
    Record $Services ([ordered]@{ origin = $origin; ref = $ServicesRef; commit = $commit; modified = $modified
                                  installed = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"); mode = $BackendMode })
    At "step backend done"
    if ($webuiWithIt) { At "step webui done" }
}

# ── Web UI as a container ───────────────────────────────────────────────────

if ((Want "webui") -and ($WebuiMode -eq "docker")) {
    At "step webui running"
    Step "Web UI: fetching $WebuiRepo ($WebuiRef) from GitHub"
    $fetched = Fetch-Repo $WebuiRepo $WebuiRef "the web UI" "webui"
    if (-not (Test-Path -LiteralPath (Join-Path $fetched.Source "docker-compose.yml"))) { Fail "This version of ai-sound-webui ($WebuiRef) has no container setup." "webui" }
    Ok "copying to $Webui"
    if (-not (Install-Copy $fetched.Source $Webui @(".windows", ".git", "node_modules", "dist", "server\.venv"))) { Fail "Could not copy the web UI to $Webui." "webui" }
    $dotenv = Join-Path $Webui ".env"
    if (-not (Test-Path -LiteralPath $dotenv)) { Copy-Item -LiteralPath (Join-Path $Webui ".env.example") -Destination $dotenv }
    $project = Project-Name
    Set-EnvValue $dotenv "SERVICES_NETWORK" "${project}_default"
    $sessions = $env:AISD_SESSIONS_DIR
    if (-not $sessions) {
        $current = (Read-Env $dotenv)["SESSIONS_DIR"]
        if (-not $current -or $current -eq "./sessions") { $sessions = Join-Path (Data-Dir) "sessions" }
    }
    if ($sessions) {
        if (-not (Test-Path -LiteralPath $sessions)) { New-Item -ItemType Directory -Force -Path $sessions | Out-Null }
        Set-EnvValue $dotenv "SESSIONS_DIR" ((Resolve-Path -LiteralPath $sessions).Path -replace "\\", "/")
    }
    Ok "Pro Tools sessions: $((Read-Env $dotenv)['SESSIONS_DIR'])"
    if ((Run "docker" @("network", "inspect", "${project}_default")) -ne 0) {
        Fail "The backend services' network (${project}_default) is not there yet. Install the backend services first, then the web UI." "webui"
    }
    At "status Building and starting the web UI container"
    At "progress -"
    if ((Run "docker" @("compose", "up", "-d", "--build") $Webui) -ne 0) { Fail "The web UI container did not start; the details say why." "webui" }
    $port = (Read-Env $dotenv)["WEBUI_PORT"]
    if (-not $port) { $port = "8030" }
    Ok "web UI: http://localhost:$port/"
    Record $Webui ([ordered]@{ origin = $WebuiRepo; ref = $WebuiRef; commit = $fetched.Commit; modified = 0
                               installed = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"); mode = "docker" })
    At "step webui done"
}

# ── Web UI on Windows beside a Docker stack ─────────────────────────────────

if ((Want "webui") -and ($WebuiMode -eq "local") -and -not (Want "backend")) {
    At "step webui running"
    Step "Web UI: served on this PC by the services' installer"
    $installer = Join-Path $Services "install_windows.ps1"
    if (-not (Test-Path -LiteralPath $installer)) { Fail "The installed backend services have no install_windows.ps1; update the backend services as well." "webui" }
    $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $installer, "-NoPrompt", "-NoBrowser", "-Only", "webui", "-WebUI", "on")
    if ($env:AISD_SESSIONS_DIR) { $arguments += @("-Sessions", $env:AISD_SESSIONS_DIR) }
    $env:AISD_GUI = "1"
    $env:AISD_WEBUI_DIR = $Webui
    if ((Run "powershell.exe" $arguments $Services) -ne 0) { Fail "The web UI could not be set up; the details say where it stopped." "webui" }
    At "step webui done"
}

# ── Pro Tools plugin ────────────────────────────────────────────────────────

if (Want "plugin") {
    At "step plugin running"
    Step "Pro Tools plugin: the newest release of $PluginRepo"
    $release = GitHub-Json "$PluginRepo/releases/latest"
    if (-not $release -or -not $release.tag_name) { Fail "GitHub could not be reached. Is this PC online?" "plugin" }
    $tag = [string]$release.tag_name
    $version = $tag.TrimStart("v")
    $asset = @($release.assets | Where-Object { $_.name -match "(?i)windows.*\.exe$" }) | Select-Object -First 1
    if (-not $asset) { Fail "The plugin release $tag has no Windows installer." "plugin" }
    $have = Plugin-Version
    if ($have -and ($have -eq $version) -and ($env:AISD_FORCE_PLUGIN -ne "1")) {
        Ok "version $have is installed, the newest"
    } else {
        if ($have -eq "?") { Ok "installed by hand (version unknown), newest: $version" }
        elseif ($have) { Ok "installed: $have, newest: $version" }
        if (Get-Process ProTools -ErrorAction SilentlyContinue) { Fail "Pro Tools is open. Close it, then click Try Again." "plugin" }
        At "status Downloading the plugin $tag"
        $setup = Join-Path (TempDir) ([string]$asset.name)
        if (-not (Download ([string]$asset.browser_download_url) $setup $true)) { Fail "The plugin download failed; try again." "plugin" }
        Write-Output ""
        At "status Installing the plugin (Windows asks for permission)"
        At "progress -"
        try {
            # Its setup asks for administrator rights itself (the User Account Control dialog)
            $process = Start-Process -FilePath $setup -ArgumentList "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART" -Wait -PassThru
            $code = $process.ExitCode
        } catch {
            Fail "The plugin was not installed (permission refused?)." "plugin"
        }
        if ($code -ne 0) { Fail "The plugin's setup stopped (code $code). Close Pro Tools and try again." "plugin" }
        $have = Plugin-Version
        if (-not $have) { Fail "The plugin's setup ran, but the plugin is not in Pro Tools' plug-in folder." "plugin" }
        Ok "installed: version $have"
    }
    At "step plugin done"
}

Cleanup

# ── Sound database ──────────────────────────────────────────────────────────

if (Want "database") {
    At "step database running"
    Step "Sound database"
    if (-not (Installed-Backend)) { Fail "The backend services are not installed; choose them as well." "database" }
    $env = Read-Env (Join-Path $Services ".env")
    $port = $env["SETUP_PORT"]
    if (-not $port) { $port = "8020" }
    $base = "http://127.0.0.1:$port"
    function Call($path, $body = $null) {
        if ($body -eq $null) { return Invoke-RestMethod -Uri "$base$path" -TimeoutSec 60 }
        return Invoke-RestMethod -Uri "$base$path" -Method Post -ContentType "application/json" -Body ($body | ConvertTo-Json -Compress) -TimeoutSec 60
    }
    At "status Waiting for the backend services"
    $deadline = (Get-Date).AddMinutes(5)
    $state = $null
    do {
        try { $state = Call "/status" } catch { Start-Sleep -Seconds 5 }
    } while (-not $state -and (Get-Date) -lt $deadline)
    if (-not $state) { Fail "The backend services do not answer (setup page on port $port); install them again." "database" }
    $audio = Want "audio"
    $steps = @{}
    foreach ($s in $state.steps) { $steps[$s.name] = $s }
    $archive = $steps.ContainsKey("bbc_archive")
    $wanted = @("bbc_metadata", "text_embeddings")
    if ($archive) { $wanted += "bbc_archive" } elseif ($audio) { $wanted += "bbc_audio" }
    $wanted += "audio_index"
    if ($audio -and -not $archive -and $steps["bbc_audio"].status -ne "complete") {
        $audioDir = $env["AUDIO_HOST_DIR"]
        if (-not $audioDir) { $audioDir = "./data/audio" }
        $audioDir = $audioDir -replace "/", "\"
        if (-not [IO.Path]::IsPathRooted($audioDir)) { $audioDir = Join-Path $Services $audioDir }
        $drive = (Split-Path -Qualifier ([IO.Path]::GetFullPath($audioDir))).TrimEnd(":")
        $free = [math]::Round((Get-PSDrive $drive).Free / 1GB)
        if ($free -lt 70) {
            Ok "The BBC audio takes about 60 GB, and drive ${drive}: has $free GB free: not started."
            Fail "The BBC audio needs about 60 GB; $free GB are free on drive ${drive}:. Free some room and try again." "database"
        }
    }
    Ok "BBC Sound Effects: free for personal, educational and research use under the BBC's terms"
    Ok "(https://sound-effects.bbcrewind.co.uk/licensing)."
    if ($audio -and -not $archive) { Ok "All of its audio (about 60 GB) is downloaded, then indexed: several hours." }
    elseif (-not $archive) {
        Ok "Without its audio: a sound is fetched the first time it is used. The search by sound and the"
        Ok "Hybrid mode's library pieces need audio on disk (the installer's audio option)."
    }
    Ok "This window can be closed at any time: the work goes on in the background, also after a"
    Ok "restart, and running the installer again shows where it is."
    At "status Starting the sound database"
    Write-Output ""
    try { Call "/pipeline/start" @{ download = [bool]$audio } | Out-Null } catch { Fail "The setup service could not start the sound database: $($_.Exception.Message)" "database" }
    $retried = @{}
    $done = @{}
    $last = ""
    while ($true) {
        Start-Sleep -Seconds 4
        try { $state = Call "/status" } catch { continue }
        $steps = @{}
        foreach ($s in $state.steps) { $steps[$s.name] = $s }
        foreach ($name in $wanted) {
            $s = $steps[$name]
            if ($s -and -not $done.ContainsKey($name) -and ($s.status -in "complete", "done")) {
                $done[$name] = $true
                Ok "$([char]0x2713) $($s.title): $($s.detail)"
            }
        }
        $running = @($wanted | Where-Object { $state.running -contains $_ })
        if ($running.Count -gt 0) {
            $s = $steps[$running[0]]
            $text = "$($s.title): $($s.detail)"
            if ($text -ne $last) {
                At "status $text"
                # Invariant culture: "100.0", not the "100,0" a German Windows would format
                if ($s.total) { At ("progress " + (100.0 * $s.done / $s.total).ToString("0.0", [Globalization.CultureInfo]::InvariantCulture)) } else { At "progress -" }
                $last = $text
            }
            continue
        }
        if ($state.pipeline.active) { continue }   # between two steps
        $failed = @($wanted | Where-Object { $steps[$_] -and $steps[$_].status -eq "error" })
        $retry = @($failed | Where-Object { -not $retried.ContainsKey($_) })
        if ($retry.Count -gt 0) {
            # A step that failed is not retried by the pipeline itself: once per run here
            Ok "$($steps[$retry[0]].title) had failed before; trying it again"
            $retried[$retry[0]] = $true
            try { Call "/jobs/$($retry[0])/start" @{} | Out-Null; Call "/pipeline/start" @{ download = [bool]$audio } | Out-Null } catch { }
            continue
        }
        if ($failed.Count -gt 0) {
            foreach ($name in $failed) {
                $s = $steps[$name]
                Ok "$($s.title) failed: $($s.error)"
                foreach ($line in $s.log) { Ok "  $line" }
            }
            Fail "$($steps[$failed[0]].title) failed; Try Again carries on where it stopped." "database"
        }
        foreach ($name in $wanted) {
            $s = $steps[$name]
            # Ran through with a few items left: files the archive does not serve or ffmpeg cannot read
            if ($s -and -not $done.ContainsKey($name) -and $s.status -eq "partial") { Ok "$($s.title): $($s.detail)" }
        }
        $sounds = 0
        if ($state.search -and $state.search.sounds) { $sounds = [int]$state.search.sounds }
        $bySound = ""
        if ($state.search -and $state.search.by_sound) { $bySound = ", search by sound available" }
        Ok ("sound database ready: " + $sounds.ToString("N0", [Globalization.CultureInfo]::InvariantCulture) + " searchable sounds" + $bySound)
        break
    }
    At "step database done"
}

Cleanup
exit 0
