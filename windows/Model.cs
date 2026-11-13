// AI Sound Design Installer: what the window shows and does (the Windows counterpart of
// macos/Installer.swift).
//
// It shows what can be installed (the backend services, the web UI, the Pro Tools plugin,
// the sound database), what of it is installed, and whether GitHub has something newer:
//   backend services   the commit in ai-services\.windows\installed-from against ai-services main
//   web UI             the commit in ai-sound-webui\.windows\installed-from against its main
//   Pro Tools plugin   the installed plugin's version against the newest release
//   this installer     its own version against the newest release of ai-sound-design/installer;
//                      it replaces itself with that one and starts again
// The work itself is done by install-components.ps1 beside the .exe, whose output this
// shows as steps, a progress bar and a log.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows;
using Microsoft.Win32;

namespace AiSoundDesign.Installer
{
    public enum Part { Backend, Webui, Plugin, Database }
    public enum RunState { Waiting, Running, Done, Failed, Skipped }
    public enum Phase { Choose, Running, Succeeded, Failed }
    public enum FreshnessKind { NotInstalled, Checking, UpToDate, Update, LocalChanges, Unknown }

    public struct Freshness
    {
        public FreshnessKind Kind;
        public string Text;   // what is new, or why no comparison was possible
        public static Freshness Of(FreshnessKind kind, string text = null) => new Freshness { Kind = kind, Text = text };
    }

    // ── Where things are ──────────────────────────────────────────────────────

    public static class Paths
    {
        static string Env(string name, string fallback) { var v = Environment.GetEnvironmentVariable(name); return string.IsNullOrEmpty(v) ? fallback : v; }

        public static readonly string Home = Env("AISD_HOME", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "AI Sound Design"));
        public static string Services => Path.Combine(Home, "ai-services");
        public static string Webui => Path.Combine(Home, "ai-sound-webui");
        public static string Choices => Path.Combine(Home, ".installer-choices");
        public static string ServicesRecord => Path.Combine(Services, @".windows\installed-from");
        public static string WebuiRecord => Path.Combine(Webui, @".windows\installed-from");
        public static readonly string Exe = Assembly.GetExecutingAssembly().Location;
        public static readonly string Dir = Path.GetDirectoryName(Exe);
        public static string Script => Path.Combine(Dir, "install-components.ps1");
        public static string InstalledDir => Path.Combine(Home, "AI Sound Design Installer");
        public static string InstalledExe => Path.Combine(InstalledDir, Path.GetFileName(Exe));
        public static readonly string PluginDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonProgramFiles), @"Avid\Audio\Plug-Ins\AI Sound Design.aaxplugin");
        public const string PluginKey = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{7C1E2B54-6D3A-4F0E-9B7B-AAX0A15D0001}_is1";
        public static readonly string DockerDesktop = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"Docker\Docker\Docker Desktop.exe");
        public static readonly string OllamaExe = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Programs\Ollama\ollama.exe");
        public static string StartMenu => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), @"Microsoft\Windows\Start Menu\Programs\AI Sound Design");

        public static readonly string ServicesRepo = Env("AISD_SERVICES_REPO", "ai-sound-design/ai-services");
        public static readonly string ServicesRef = Env("AISD_SERVICES_REF", "main");
        public static readonly string WebuiRepo = Env("AISD_WEBUI_REPO", "ai-sound-design/ai-sound-webui");
        public static readonly string WebuiRef = Env("AISD_WEBUI_REF", "main");
        public static readonly string PluginRepo = Env("AISD_PLUGIN_REPO", "ai-sound-design/ai-protools-aax");
        public static readonly string InstallerRepo = Env("AISD_INSTALLER_REPO", "ai-sound-design/installer");

        public static bool OnPath(string exe)
        {
            var path = Environment.GetEnvironmentVariable("PATH") ?? "";
            return path.Split(';').Any(d => { try { return d.Length > 0 && File.Exists(Path.Combine(d, exe)); } catch { return false; } });
        }
        public static bool DockerInstalled => File.Exists(DockerDesktop) || OnPath("docker.exe");
        public static bool OllamaInstalled => File.Exists(OllamaExe) || OnPath("ollama.exe");
    }

    public static class Text
    {
        public static readonly string InstallerVersion = Assembly.GetExecutingAssembly().GetName().Version is Version v ? (v.Build < 0 ? v.ToString() : $"{v.Major}.{v.Minor}.{v.Build}") : "0";

        /// KEY=value lines (.env, installed-from)
        public static Dictionary<string, string> ReadKeyValues(string path)
        {
            var values = new Dictionary<string, string>();
            try
            {
                if (!File.Exists(path)) return values;
                foreach (var raw in File.ReadAllLines(path))
                {
                    var line = raw.Trim();
                    if (line.StartsWith("#") || !line.Contains("=")) continue;
                    var eq = line.IndexOf('=');
                    var key = line.Substring(0, eq).Trim();
                    var value = line.Substring(eq + 1).Trim();
                    if (value.Length >= 2 && value.StartsWith("\"") && value.EndsWith("\"")) value = value.Substring(1, value.Length - 2);
                    values[key] = value;
                }
            }
            catch (Exception) { }
            return values;
        }

        public static string ShortPath(string path)
        {
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            return path.StartsWith(home, StringComparison.OrdinalIgnoreCase) ? "~" + path.Substring(home.Length) : path;
        }

        public static bool IsNewer(string latest, string have)
        {
            Version a, b;
            if (Version.TryParse(Clean(latest), out a) && Version.TryParse(Clean(have), out b)) return a > b;
            return string.CompareOrdinal(Clean(latest), Clean(have)) > 0;
        }
        static string Clean(string v)
        {
            v = v.StartsWith("v") ? v.Substring(1) : v;
            return v.Count(c => c == '.') == 0 ? v + ".0" : v;
        }
    }

    // ── GitHub ────────────────────────────────────────────────────────────────

    public class Commit
    {
        public string Sha, Message; public DateTime? Date;
        public string Summary
        {
            get
            {
                var first = (Message ?? "").Split('\n')[0];
                var brief = first.Length > 90 ? first.Substring(0, 87) + "…" : first;
                return Date.HasValue ? $"{brief} ({Date.Value.ToLocalTime():d MMM yyyy})" : brief;
            }
        }
    }

    public class Release
    {
        public string Tag; public Dictionary<string, string> Assets = new Dictionary<string, string>();
        public string Version => Tag.StartsWith("v") ? Tag.Substring(1) : Tag;
    }

    public static class GitHub
    {
        static readonly HttpClient Client = Make();
        static HttpClient Make()
        {
            var client = new HttpClient { Timeout = TimeSpan.FromSeconds(12) };
            client.DefaultRequestHeaders.UserAgent.ParseAdd("ai-sound-design-installer");
            client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
            return client;
        }
        static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };

        public static async Task<Dictionary<string, object>> JsonAsync(string path)
        {
            try
            {
                var text = await Client.GetStringAsync("https://api.github.com/repos/" + path);
                return Json.DeserializeObject(text) as Dictionary<string, object>;
            }
            catch (Exception) { return null; }
        }

        public static async Task<Dictionary<string, object>> LocalJsonAsync(string url, int seconds = 8)
        {
            try
            {
                using (var client = new HttpClient { Timeout = TimeSpan.FromSeconds(seconds) })
                {
                    var text = await client.GetStringAsync(url);
                    return Json.DeserializeObject(text) as Dictionary<string, object>;
                }
            }
            catch (Exception) { return null; }
        }

        public static async Task<Commit> LatestCommitAsync(string repo, string reference)
        {
            var json = await JsonAsync($"{repo}/commits/{reference}");
            var sha = Get(json, "sha") as string;
            if (sha == null) return null;
            var commit = Get(json, "commit") as Dictionary<string, object>;
            var committer = Get(commit, "committer") as Dictionary<string, object>;
            DateTime date;
            var when = Get(committer, "date") as string;
            return new Commit
            {
                Sha = sha, Message = Get(commit, "message") as string ?? "",
                Date = when != null && DateTime.TryParse(when, null, System.Globalization.DateTimeStyles.AdjustToUniversal, out date) ? date : (DateTime?)null
            };
        }

        public static async Task<Release> LatestReleaseAsync(string repo)
        {
            var json = await JsonAsync($"{repo}/releases/latest");
            var tag = Get(json, "tag_name") as string;
            if (tag == null) return null;
            var release = new Release { Tag = tag };
            foreach (var item in Get(json, "assets") as object[] ?? new object[0])
            {
                var asset = item as Dictionary<string, object>;
                var name = Get(asset, "name") as string;
                var url = Get(asset, "browser_download_url") as string;
                if (name != null && url != null) release.Assets[name] = url;
            }
            return release;
        }

        public static object Get(Dictionary<string, object> dict, string key)
        {
            object value;
            return dict != null && dict.TryGetValue(key, out value) ? value : null;
        }
    }

    // ── Model ─────────────────────────────────────────────────────────────────

    public class Model : INotifyPropertyChanged
    {
        public static Model Shared;
        public event PropertyChangedEventHandler PropertyChanged;
        public event Action Changed;
        void Notify() { PropertyChanged?.Invoke(this, new PropertyChangedEventArgs("")); Changed?.Invoke(); }

        public Phase Phase = Phase.Choose;
        public HashSet<Part> Chosen = new HashSet<Part>();
        public bool Audio;
        public string DataDir = "", SessionsDir = "", BbcArchive = "", OwnSounds = "";
        public string BackendMode = "docker", WebuiMode = "docker", Ollama = "docker";   // docker | local, docker | host

        public bool BackendInstalled, WebuiInstalled;
        public string InstalledBackendMode, InstalledWebuiMode;   // docker | local
        public string PluginInstalled;      // version, "?" when put there by hand, null when absent
        public string PluginLatest;
        public Dictionary<Part, Freshness> Fresh = new Dictionary<Part, Freshness>();
        public int? DatabaseSounds;
        public bool DatabaseLoading;
        public int Checking;

        public Release InstallerUpdate;
        public bool SelfUpdating;
        public string SelfUpdateError;

        public Dictionary<Part, RunState> States = new Dictionary<Part, RunState>();
        public string Status = "";
        public double? Progress;
        public List<string> Log = new List<string>();
        public string ErrorMessage;
        public bool InDatabasePhase;

        bool touched;     // the user changed the selection: no more automatic ticks
        Process process;
        FileStream logFile;
        readonly List<byte> buffer = new List<byte>();
        bool replaceLast;
        List<Part> runParts = new List<Part>();

        public static string Title(Part part)
        {
            switch (part)
            {
                case Part.Backend: return "Backend services";
                case Part.Webui: return "Web UI";
                case Part.Plugin: return "Pro Tools plugin (AAX)";
                default: return "Sound database";
            }
        }
        public static string Key(Part part) => part.ToString().ToLowerInvariant();
        public static readonly Part[] AllParts = { Part.Backend, Part.Webui, Part.Plugin, Part.Database };

        public Model() { Shared = this; }

        // ── what is installed, what GitHub has ────────────────────────────────

        public void Refresh()
        {
            var env = Text.ReadKeyValues(Path.Combine(Paths.Services, ".env"));
            var record = Text.ReadKeyValues(Paths.ServicesRecord);
            BackendInstalled = File.Exists(Path.Combine(Paths.Services, ".env")) && File.Exists(Path.Combine(Paths.Services, "docker-compose.yml"));
            InstalledBackendMode = BackendInstalled ? (record.ContainsKey("mode") ? record["mode"] : (Directory.Exists(Path.Combine(Paths.Services, @".windows\pgsql")) ? "local" : "docker")) : null;
            var webuiRecord = Text.ReadKeyValues(Paths.WebuiRecord);
            WebuiInstalled = webuiRecord.ContainsKey("commit") || File.Exists(Path.Combine(Paths.Webui, @"dist\index.html"));
            InstalledWebuiMode = WebuiInstalled ? (webuiRecord.ContainsKey("mode") ? webuiRecord["mode"] : (File.Exists(Path.Combine(Paths.Webui, @"dist\index.html")) ? "local" : "docker")) : null;
            PluginInstalled = PluginVersion();

            if (BackendInstalled)
            {
                BackendMode = InstalledBackendMode;
                var audio = env.ContainsKey("AUDIO_HOST_DIR") ? env["AUDIO_HOST_DIR"].Replace('/', '\\') : "";
                var data = audio.Length > 0 ? Path.GetDirectoryName(audio) ?? "" : "";
                if (data == "" || data == "." || !Path.IsPathRooted(data))
                    data = Path.GetFullPath(Path.Combine(Paths.Services, data.StartsWith(".\\") ? data.Substring(2) : (data == "" || data == "." ? "data" : data)));
                DataDir = data;
                Ollama = env.ContainsKey("BUNDLED_OLLAMA") && env["BUNDLED_OLLAMA"] == "0" ? "host" : "docker";
            }
            else
            {
                BackendMode = Paths.DockerInstalled ? "docker" : "local";
                Ollama = Paths.OllamaInstalled ? "host" : "docker";
            }
            WebuiMode = WebuiInstalled ? InstalledWebuiMode : BackendMode;
            if (BackendMode == "local") Ollama = "host";
            var webuiEnv = Text.ReadKeyValues(Path.Combine(Paths.Webui, ".env"));
            if (env.ContainsKey("WEBUI_SESSIONS_DIRS") && env["WEBUI_SESSIONS_DIRS"].Length > 0) SessionsDir = env["WEBUI_SESSIONS_DIRS"].Replace('/', '\\');
            else if (webuiEnv.ContainsKey("SESSIONS_DIR") && webuiEnv["SESSIONS_DIR"].Length > 0 && webuiEnv["SESSIONS_DIR"] != "./sessions") SessionsDir = webuiEnv["SESSIONS_DIR"].Replace('/', '\\');
            if (env.ContainsKey("BBC_ARCHIVE_HOST_DIR") && !env["BBC_ARCHIVE_HOST_DIR"].EndsWith("/data/archive") && !env["BBC_ARCHIVE_HOST_DIR"].EndsWith("\\data\\archive")) BbcArchive = env["BBC_ARCHIVE_HOST_DIR"].Replace('/', '\\');
            if (env.ContainsKey("OWN_SOUNDS_HOST_DIR") && !env["OWN_SOUNDS_HOST_DIR"].EndsWith("/data/own-sounds") && !env["OWN_SOUNDS_HOST_DIR"].EndsWith("\\data\\own-sounds")) OwnSounds = env["OWN_SOUNDS_HOST_DIR"].Replace('/', '\\');

            Fresh[Part.Backend] = Freshness.Of(BackendInstalled ? FreshnessKind.Checking : FreshnessKind.NotInstalled);
            Fresh[Part.Webui] = Freshness.Of(WebuiInstalled ? FreshnessKind.Checking : FreshnessKind.NotInstalled);
            Fresh[Part.Plugin] = Freshness.Of(PluginInstalled != null ? FreshnessKind.Checking : FreshnessKind.NotInstalled);
            Fresh[Part.Database] = Freshness.Of(FreshnessKind.Unknown);
            ApplyDefaults();
            Notify();
            CheckServices(record);
            CheckWebui(webuiRecord);
            CheckPlugin();
            CheckDatabase(env);
            CheckInstaller();
        }

        static string PluginVersion()
        {
            try
            {
                using (var hklm = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
                using (var key = hklm.OpenSubKey(Paths.PluginKey))
                {
                    var version = key?.GetValue("DisplayVersion") as string;
                    if (!string.IsNullOrEmpty(version)) return version.TrimStart('v');
                }
            }
            catch (Exception) { }
            return Directory.Exists(Path.Combine(Paths.PluginDir, @"Contents\x64")) ? "?" : null;
        }

        async void Track(Func<Task> work)
        {
            Checking++;
            Notify();
            try { await work(); } catch (Exception) { }
            Checking--;
            ApplyDefaults();
            Notify();
        }

        void CheckServices(Dictionary<string, string> record)
        {
            if (!BackendInstalled) return;
            Track(async () =>
            {
                if (record.ContainsKey("modified") && record["modified"] == "1") { Fresh[Part.Backend] = Freshness.Of(FreshnessKind.LocalChanges); return; }
                var have = record.ContainsKey("commit") ? record["commit"] : "";
                if (have.Length == 0) { Fresh[Part.Backend] = Freshness.Of(FreshnessKind.Unknown, "installed version unknown"); return; }
                var latest = await GitHub.LatestCommitAsync(Paths.ServicesRepo, record.ContainsKey("ref") && record["ref"].Length > 0 ? record["ref"] : Paths.ServicesRef);
                if (latest == null) { Fresh[Part.Backend] = Freshness.Of(FreshnessKind.Unknown, "GitHub not reachable"); return; }
                Fresh[Part.Backend] = latest.Sha == have ? Freshness.Of(FreshnessKind.UpToDate) : Freshness.Of(FreshnessKind.Update, latest.Summary);
            });
        }

        void CheckWebui(Dictionary<string, string> record)
        {
            if (!WebuiInstalled) return;
            Track(async () =>
            {
                var have = record.ContainsKey("commit") ? record["commit"] : "";
                if (have.Length != 40) { Fresh[Part.Webui] = Freshness.Of(FreshnessKind.Unknown, "installed version unknown"); return; }
                var latest = await GitHub.LatestCommitAsync(Paths.WebuiRepo, record.ContainsKey("ref") && record["ref"].Length > 0 ? record["ref"] : Paths.WebuiRef);
                if (latest == null) { Fresh[Part.Webui] = Freshness.Of(FreshnessKind.Unknown, "GitHub not reachable"); return; }
                Fresh[Part.Webui] = latest.Sha == have ? Freshness.Of(FreshnessKind.UpToDate) : Freshness.Of(FreshnessKind.Update, latest.Summary);
            });
        }

        void CheckPlugin()
        {
            var have = PluginInstalled;
            Track(async () =>
            {
                var release = await GitHub.LatestReleaseAsync(Paths.PluginRepo);
                if (release == null) { Fresh[Part.Plugin] = have == null ? Freshness.Of(FreshnessKind.NotInstalled) : Freshness.Of(FreshnessKind.Unknown, "GitHub not reachable"); return; }
                PluginLatest = release.Version;
                if (have == null) { Fresh[Part.Plugin] = Freshness.Of(FreshnessKind.NotInstalled); return; }
                if (have == "?") { Fresh[Part.Plugin] = Freshness.Of(FreshnessKind.Unknown, "installed by hand, version unknown; newest: " + release.Version); return; }
                Fresh[Part.Plugin] = Text.IsNewer(release.Version, have) ? Freshness.Of(FreshnessKind.Update, "Version " + release.Version) : Freshness.Of(FreshnessKind.UpToDate);
            });
        }

        void CheckDatabase(Dictionary<string, string> env)
        {
            if (!BackendInstalled) { DatabaseSounds = null; return; }
            var port = env.ContainsKey("SETUP_PORT") && env["SETUP_PORT"].Length > 0 ? env["SETUP_PORT"] : "8020";
            Track(async () =>
            {
                var json = await GitHub.LocalJsonAsync($"http://127.0.0.1:{port}/status");
                if (json == null) return;
                var search = GitHub.Get(json, "search") as Dictionary<string, object>;
                var sounds = GitHub.Get(search, "sounds");
                DatabaseSounds = sounds is int i ? i : (sounds is long l ? (int)l : (int?)null);
                var pipeline = GitHub.Get(json, "pipeline") as Dictionary<string, object>;
                DatabaseLoading = GitHub.Get(pipeline, "active") is bool b && b;
            });
        }

        void CheckInstaller()
        {
            // For testing the self-update without publishing: AISD_INSTALLER_UPDATE="<version> <zip URL>"
            // (a third word "now" starts it at once)
            var fake = (Environment.GetEnvironmentVariable("AISD_INSTALLER_UPDATE") ?? "").Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
            if (fake.Length >= 2)
            {
                InstallerUpdate = new Release { Tag = fake[0], Assets = { ["AI-Sound-Design-Installer-Windows.zip"] = fake[1] } };
                if (fake.Length > 2 && fake[2] == "now") UpdateInstaller();
                return;
            }
            Track(async () =>
            {
                var release = await GitHub.LatestReleaseAsync(Paths.InstallerRepo);
                if (release != null && Text.IsNewer(release.Version, Text.InstallerVersion) && release.Assets.Keys.Any(IsWindowsZip))
                    InstallerUpdate = release;
            });
        }

        static bool IsWindowsZip(string name) => name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase) && name.IndexOf("windows", StringComparison.OrdinalIgnoreCase) >= 0;

        public bool HasUpdate(Part part) => Fresh.ContainsKey(part) && Fresh[part].Kind == FreshnessKind.Update;
        public List<Part> Updates => AllParts.Where(HasUpdate).ToList();
        public bool AnyInstalled => BackendInstalled || PluginInstalled != null;

        /// Ticks what an update is there for (nothing installed yet: the services), and the
        /// database while it is still loading; until the user changes the selection
        void ApplyDefaults()
        {
            if (touched || Phase != Phase.Choose) return;
            var picked = new HashSet<Part>(Updates);
            if (!BackendInstalled && PluginInstalled == null) picked.Add(Part.Backend);
            var remembered = "";
            try { if (File.Exists(Paths.Choices)) remembered = File.ReadAllText(Paths.Choices); } catch (Exception) { }
            if (DatabaseLoading || (remembered.Contains("database") && BackendInstalled && (DatabaseSounds ?? 0) == 0))
            {
                picked.Add(Part.Database);
                Audio = remembered.Contains("audio");
            }
            Chosen = picked;
        }

        // The web UI needs the services (their network, or their installer); the database needs them there
        public bool BackendRequired => !BackendInstalled && (Chosen.Contains(Part.Webui) || Chosen.Contains(Part.Database));

        public bool IsOn(Part part) => Chosen.Contains(part) || (part == Part.Backend && BackendRequired);

        public void Set(Part part, bool on)
        {
            touched = true;
            if (on) Chosen.Add(part); else Chosen.Remove(part);
            if (part == Part.Database && !on) Audio = false;
            Notify();
        }

        public List<Part> Parts => AllParts.Where(IsOn).ToList();

        public string ActionTitle
        {
            get
            {
                var parts = Parts;
                if (parts.Count == 0) return AnyInstalled ? "Update" : "Install";
                var installs = parts.Any(p => (p == Part.Backend && !BackendInstalled) || (p == Part.Webui && !WebuiInstalled) || (p == Part.Plugin && PluginInstalled == null));
                var refreshes = parts.Any(p => (p == Part.Backend && BackendInstalled) || (p == Part.Webui && WebuiInstalled) || (p == Part.Plugin && PluginInstalled != null));
                if (installs && refreshes) return "Install and Update";
                if (installs) return "Install";
                if (parts.Count == 1 && parts[0] == Part.Database) return "Load";
                return "Update";
            }
        }

        // ── updating the installer itself ─────────────────────────────────────

        public async void UpdateInstaller()
        {
            var release = InstallerUpdate;
            var zipName = release?.Assets.Keys.FirstOrDefault(IsWindowsZip);
            if (zipName == null) return;
            SelfUpdating = true;
            SelfUpdateError = null;
            Notify();
            try
            {
                var work = Path.Combine(Path.GetTempPath(), "ai-sound-installer-" + Guid.NewGuid().ToString("N").Substring(0, 8));
                Directory.CreateDirectory(work);
                var zip = Path.Combine(work, "installer.zip");
                using (var client = new HttpClient { Timeout = TimeSpan.FromMinutes(5) })
                using (var stream = await client.GetStreamAsync(release.Assets[zipName]))
                using (var file = File.Create(zip))
                    await stream.CopyToAsync(file);
                var unpacked = Path.Combine(work, "unpacked");
                ZipFile.ExtractToDirectory(zip, unpacked);
                var exe = Directory.GetFiles(unpacked, "*.exe", SearchOption.AllDirectories).FirstOrDefault();
                if (exe == null) throw new Exception("the download holds no program");
                var source = Path.GetDirectoryName(exe);
                // In place when the running copy may be replaced; else into ~\AI Sound Design
                var inPlace = Writable(Paths.Dir);
                var targetDir = inPlace ? Paths.Dir : Paths.InstalledDir;
                Directory.CreateDirectory(targetDir);
                foreach (var file in Directory.GetFiles(source))
                {
                    var target = Path.Combine(targetDir, Path.GetFileName(file));
                    if (string.Equals(target, Paths.Exe, StringComparison.OrdinalIgnoreCase))
                    {
                        // A running program cannot be overwritten, but renamed
                        var old = target + ".old";
                        if (File.Exists(old)) File.Delete(old);
                        File.Move(target, old);
                    }
                    File.Copy(file, target, true);
                    Unblock(target);
                }
                try { Directory.Delete(work, true); } catch (Exception) { }
                Process.Start(new ProcessStartInfo(Path.Combine(targetDir, Path.GetFileName(exe))) { UseShellExecute = true });
                Application.Current.Shutdown();
            }
            catch (Exception error)
            {
                SelfUpdating = false;
                SelfUpdateError = "The installer could not update itself: " + error.Message;
                Notify();
            }
        }

        static bool Writable(string dir)
        {
            try
            {
                var probe = Path.Combine(dir, ".write-" + Guid.NewGuid().ToString("N"));
                File.WriteAllText(probe, "");
                File.Delete(probe);
                return true;
            }
            catch (Exception) { return false; }
        }

        /// Removes the mark a download carries ("this file came from another computer")
        static void Unblock(string file)
        {
            try { File.Delete(file + ":Zone.Identifier"); } catch (Exception) { }
        }

        // ── running install-components.ps1 ────────────────────────────────────

        public void Start()
        {
            runParts = Parts;
            if (runParts.Count == 0) return;
            States = runParts.ToDictionary(p => p, p => RunState.Waiting);
            Log.Clear();
            Status = "Starting";
            Progress = null;
            ErrorMessage = null;
            InDatabasePhase = false;
            Phase = Phase.Running;
            try { Directory.CreateDirectory(Paths.Home); } catch (Exception) { }
            var remembered = runParts.Select(Key).ToList();
            if (Audio && runParts.Contains(Part.Database)) remembered.Add("audio");
            try { File.WriteAllText(Paths.Choices, string.Join(" ", remembered) + "\n"); } catch (Exception) { }
            // The whole output also in ~\AI Sound Design\installer.log, for when something needs explaining
            try
            {
                logFile = new FileStream(Path.Combine(Paths.Home, "installer.log"), FileMode.Create, FileAccess.Write, FileShare.Read);
                var head = Encoding.UTF8.GetBytes($"AI Sound Design Installer {Text.InstallerVersion}: {string.Join(" ", remembered)}\r\n");
                logFile.Write(head, 0, head.Length);
            }
            catch (Exception) { logFile = null; }

            var info = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{Paths.Script}\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
                WorkingDirectory = Paths.Dir,
            };
            var env = info.Environment;
            env["AISD_GUI"] = "1";
            env["AISD_HOME"] = Paths.Home;
            env["AISD_COMPONENTS"] = string.Join(" ", remembered);
            env["AISD_BACKEND_MODE"] = BackendMode;
            env["AISD_WEBUI_MODE"] = WebuiMode;
            env["AISD_OLLAMA"] = Ollama;
            env["PYTHONUNBUFFERED"] = "1";
            env["PYTHONUTF8"] = "1";
            var folders = new Dictionary<string, string>
            {
                ["AISD_DATA_DIR"] = BackendInstalled ? "" : DataDir, ["AISD_SESSIONS_DIR"] = SessionsDir,
                ["AISD_BBC_ARCHIVE"] = BbcArchive, ["AISD_OWN_SOUNDS"] = OwnSounds
            };
            foreach (var pair in folders) if (!string.IsNullOrEmpty(pair.Value)) env[pair.Key] = pair.Value;
            try
            {
                process = new Process { StartInfo = info, EnableRaisingEvents = true };
                process.Exited += (s, e) => Application.Current.Dispatcher.BeginInvoke(new Action(() => Ended(process?.ExitCode ?? 1)));
                process.Start();
                process.StandardInput.Close();
                Read(process.StandardOutput.BaseStream, 0);
                Read(process.StandardError.BaseStream, 1);
            }
            catch (Exception error)
            {
                ErrorMessage = "The installer could not start: " + error.Message;
                Phase = Phase.Failed;
            }
            Notify();
        }

        void Read(Stream stream, int which)
        {
            var thread = new Thread(() =>
            {
                var chunk = new byte[4096];
                int n;
                try
                {
                    while ((n = stream.Read(chunk, 0, chunk.Length)) > 0)
                    {
                        var data = new byte[n];
                        Array.Copy(chunk, data, n);
                        Application.Current.Dispatcher.BeginInvoke(new Action(() => Consume(data, which)));
                    }
                }
                catch (Exception) { }
            }) { IsBackground = true };
            thread.Start();
        }

        public void Stop()
        {
            var p = process;
            if (p == null) return;
            try
            {
                if (p.HasExited) return;
                // The script and everything it started (pip, curl, the database monitor)
                Process.Start(new ProcessStartInfo("taskkill", $"/PID {p.Id} /T /F") { CreateNoWindow = true, UseShellExecute = false })?.WaitForExit(10000);
            }
            catch (Exception) { }
        }

        public bool IsRunning { get { try { return process != null && !process.HasExited; } catch (Exception) { return false; } } }

        void Ended(int code)
        {
            process = null;
            FlushBuffer();
            try { logFile?.Close(); } catch (Exception) { }
            logFile = null;
            if (code == 0)
            {
                foreach (var part in runParts) if (States[part] != RunState.Done && States[part] != RunState.Skipped) States[part] = RunState.Done;
                Phase = Phase.Succeeded;
                Status = "";
                CopySelf();
            }
            else
            {
                foreach (var part in runParts) if (States[part] == RunState.Running) States[part] = RunState.Failed;
                if (ErrorMessage == null) ErrorMessage = "The installation stopped. The details below say where.";
                Phase = Phase.Failed;
            }
            touched = false;
            Refresh();
        }

        /// The installer beside the installation, to update and add parts later, with a
        /// Start menu entry; and Start menu links to the web UI and the setup page
        void CopySelf()
        {
            try
            {
                if (!Directory.Exists(Paths.Home)) return;
                if (!string.Equals(Path.GetFullPath(Paths.Dir).TrimEnd('\\'), Path.GetFullPath(Paths.InstalledDir).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                {
                    Directory.CreateDirectory(Paths.InstalledDir);
                    foreach (var file in new[] { Paths.Exe, Paths.Script })
                    {
                        if (!File.Exists(file)) continue;
                        var target = Path.Combine(Paths.InstalledDir, Path.GetFileName(file));
                        File.Copy(file, target, true);
                        Unblock(target);
                    }
                }
                Directory.CreateDirectory(Paths.StartMenu);
                Shortcut(Path.Combine(Paths.StartMenu, "AI Sound Design Installer.lnk"), Paths.InstalledExe);
                var env = Text.ReadKeyValues(Path.Combine(Paths.Services, ".env"));
                if (BackendInstalled || File.Exists(Path.Combine(Paths.Services, ".env")))
                {
                    var setup = env.ContainsKey("SETUP_PORT") && env["SETUP_PORT"].Length > 0 ? env["SETUP_PORT"] : "8020";
                    File.WriteAllText(Path.Combine(Paths.StartMenu, "Setup page.url"), $"[InternetShortcut]\r\nURL=http://localhost:{setup}/\r\n");
                }
                if (WebuiInstalled || Directory.Exists(Path.Combine(Paths.Webui, ".windows")))
                {
                    var webuiEnv = Text.ReadKeyValues(Path.Combine(Paths.Webui, ".env"));
                    var port = webuiEnv.ContainsKey("WEBUI_PORT") && webuiEnv["WEBUI_PORT"].Length > 0 ? webuiEnv["WEBUI_PORT"]
                        : (env.ContainsKey("WEBUI_PORT") && env["WEBUI_PORT"].Length > 0 ? env["WEBUI_PORT"] : "8030");
                    File.WriteAllText(Path.Combine(Paths.StartMenu, "AI Sound Design (Web UI).url"), $"[InternetShortcut]\r\nURL=http://localhost:{port}/\r\n");
                }
            }
            catch (Exception) { }
        }

        static void Shortcut(string link, string target)
        {
            try
            {
                var type = Type.GetTypeFromProgID("WScript.Shell");
                var shell = Activator.CreateInstance(type);
                var shortcut = type.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { link });
                var t = shortcut.GetType();
                t.InvokeMember("TargetPath", BindingFlags.SetProperty, null, shortcut, new object[] { target });
                t.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, shortcut, new object[] { Path.GetDirectoryName(target) });
                t.InvokeMember("Description", BindingFlags.SetProperty, null, shortcut, new object[] { "Installs and updates AI Sound Design" });
                t.InvokeMember("Save", BindingFlags.InvokeMethod, null, shortcut, null);
            }
            catch (Exception) { }
        }

        public string WebuiUrl
        {
            get
            {
                var env = Text.ReadKeyValues(Path.Combine(Paths.Services, ".env"));
                var webuiEnv = Text.ReadKeyValues(Path.Combine(Paths.Webui, ".env"));
                var port = webuiEnv.ContainsKey("WEBUI_PORT") && webuiEnv["WEBUI_PORT"].Length > 0 ? webuiEnv["WEBUI_PORT"]
                    : (env.ContainsKey("WEBUI_PORT") && env["WEBUI_PORT"].Length > 0 ? env["WEBUI_PORT"] : "8030");
                return $"http://localhost:{port}/";
            }
        }

        public string SetupUrl
        {
            get
            {
                var env = Text.ReadKeyValues(Path.Combine(Paths.Services, ".env"));
                var port = env.ContainsKey("SETUP_PORT") && env["SETUP_PORT"].Length > 0 ? env["SETUP_PORT"] : "8020";
                return $"http://localhost:{port}/";
            }
        }

        // ── output ────────────────────────────────────────────────────────────

        readonly List<byte>[] buffers = { new List<byte>(), new List<byte>() };
        readonly bool[] pendingReturn = { false, false };

        void Consume(byte[] data, int which)
        {
            try { logFile?.Write(data, 0, data.Length); logFile?.Flush(); } catch (Exception) { }
            var buf = buffers[which];
            foreach (var b in data)
            {
                if (pendingReturn[which])
                {
                    // A carriage return followed by a line feed is Windows' line end; one on
                    // its own rewrites the line (curl's progress bar)
                    pendingReturn[which] = false;
                    Emit(Encoding.UTF8.GetString(buf.ToArray()), b != 10);
                    buf.Clear();
                    if (b == 10) continue;
                }
                if (b == 13) { pendingReturn[which] = true; continue; }
                if (b == 10)
                {
                    Emit(Encoding.UTF8.GetString(buf.ToArray()), false);
                    buf.Clear();
                    continue;
                }
                buf.Add(b);
            }
            Notify();
        }

        void FlushBuffer()
        {
            for (var which = 0; which < buffers.Length; which++)
            {
                var buf = buffers[which];
                if (buf.Count > 0 || pendingReturn[which]) Emit(Encoding.UTF8.GetString(buf.ToArray()), false);
                buf.Clear();
                pendingReturn[which] = false;
            }
        }

        static readonly Regex Ansi = new Regex("\u001B\\[[0-9;?]*[A-Za-z]");
        static readonly Regex Percent = new Regex(@"(\d{1,3}(?:\.\d+)?)%");

        void Emit(string raw, bool carriageReturn)
        {
            var line = Ansi.Replace(raw, "");
            var wasReplacing = replaceLast;
            replaceLast = carriageReturn;
            if (line.StartsWith("@@")) { Command(line.Substring(2)); return; }
            if (line.Trim().Length == 0 && !wasReplacing) return;
            if (wasReplacing && Log.Count > 0) Log[Log.Count - 1] = line; else Log.Add(line);
            if (Log.Count > 4000) Log.RemoveRange(0, Log.Count - 4000);
            var trimmed = line.Trim();
            if (trimmed.StartsWith("== "))
            {
                Status = trimmed.Substring(3);
                Progress = null;
            }
            else if (carriageReturn || wasReplacing || trimmed.Contains("%|"))
            {
                var match = Percent.Match(line);
                double value;
                if (match.Success && double.TryParse(match.Groups[1].Value, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out value) && value <= 100)
                    Progress = value / 100;
            }
        }

        /// @@step <part> <running|done|failed|skipped>, @@status <text>, @@progress <0-100|->, @@error <text>
        void Command(string text)
        {
            var words = text.Split(new[] { ' ' }, 2);
            var verb = words[0];
            var rest = words.Length > 1 ? words[1] : "";
            switch (verb)
            {
                case "step":
                    var args = rest.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
                    if (args.Length < 2) return;
                    Part part;
                    if (!Enum.TryParse(args[0], true, out part)) return;
                    var states = new Dictionary<string, RunState> { ["running"] = RunState.Running, ["done"] = RunState.Done, ["failed"] = RunState.Failed, ["skipped"] = RunState.Skipped };
                    States[part] = states.ContainsKey(args[1]) ? states[args[1]] : RunState.Waiting;
                    if (args[1] == "running")
                    {
                        Status = Title(part);
                        Progress = null;
                        InDatabasePhase = part == Part.Database;
                    }
                    break;
                case "status":
                    Status = rest;
                    break;
                case "progress":
                    double value;
                    Progress = double.TryParse(rest, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out value) ? Math.Min(Math.Max(value / 100, 0), 1) : (double?)null;
                    break;
                case "error":
                    // The first one says what went wrong; later ones only that it stopped
                    if (ErrorMessage == null) ErrorMessage = rest;
                    break;
            }
        }
    }
}
