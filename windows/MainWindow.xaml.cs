using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace AiSoundDesign.Installer
{
    public partial class MainWindow : Window
    {
        readonly Model model = new Model();
        readonly DispatcherTimer timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
        bool dirty, rendering;
        int logShown = -1;

        public MainWindow()
        {
            InitializeComponent();
            if (!File.Exists(Paths.Script))
            {
                MessageBox.Show($"install-components.ps1 is missing beside the installer:\n{Paths.Script}\n\nUnpack the whole ZIP, then open the installer from the unpacked folder.", "AI Sound Design Installer", MessageBoxButton.OK, MessageBoxImage.Error);
            }
            model.Changed += () => dirty = true;
            timer.Tick += (s, e) => { if (dirty && !rendering) { dirty = false; Render(); } };
            timer.Start();
            Closing += (s, e) =>
            {
                if (!model.IsRunning || model.InDatabasePhase) return;
                if (MessageBox.Show("Stop the installation?\nWhat is half done is finished the next time.", "AI Sound Design Installer", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) { e.Cancel = true; return; }
                model.Stop();
            };
            model.Refresh();
            Render();
            // For a picture of the window without a hand on the mouse (the README, a test):
            // AISD_SCREENSHOT=<file.png> renders it, after the GitHub checks (or after
            // AISD_SCREENSHOT_DELAY seconds, for a picture of a run), and quits
            var shot = Environment.GetEnvironmentVariable("AISD_SCREENSHOT");
            if (!string.IsNullOrEmpty(shot))
            {
                double delay;
                if (!double.TryParse(Environment.GetEnvironmentVariable("AISD_SCREENSHOT_DELAY"), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out delay)) delay = 4;
                var wait = new DispatcherTimer { Interval = TimeSpan.FromSeconds(delay) };
                wait.Tick += (s, e) => { wait.Stop(); Render(); Dispatcher.BeginInvoke(new Action(() => Screenshot(shot)), DispatcherPriority.ContextIdle); };
                wait.Start();
            }
        }

        void Screenshot(string file)
        {
            try
            {
                var root = (FrameworkElement)Content;
                var bitmap = new System.Windows.Media.Imaging.RenderTargetBitmap((int)root.ActualWidth, (int)root.ActualHeight, 96, 96, PixelFormats.Pbgra32);
                bitmap.Render(root);
                var encoder = new System.Windows.Media.Imaging.PngBitmapEncoder();
                encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bitmap));
                using (var stream = File.Create(file)) encoder.Save(stream);
            }
            catch (Exception) { }
            Close();
        }

        // ── the choice ────────────────────────────────────────────────────────

        void Render()
        {
            rendering = true;
            try
            {
                ChoosePanel.Visibility = model.Phase == Phase.Choose ? Visibility.Visible : Visibility.Collapsed;
                RunPanel.Visibility = model.Phase == Phase.Choose ? Visibility.Collapsed : Visibility.Visible;
                if (model.Phase == Phase.Choose) RenderChoice(); else RenderRun();
            }
            finally { rendering = false; }
        }

        void RenderChoice()
        {
            Subtitle.Text = SubtitleText();
            UpdateBanner.Visibility = model.InstallerUpdate != null ? Visibility.Visible : Visibility.Collapsed;
            if (model.InstallerUpdate != null)
            {
                UpdateTitle.Text = $"A new installer is available: {model.InstallerUpdate.Version}";
                UpdateDetail.Text = model.SelfUpdateError ?? (model.SelfUpdating ? "Downloading…" : $"This is {Text.InstallerVersion}. It replaces this one and opens again.");
                UpdateInstallerButton.IsEnabled = !model.SelfUpdating;
            }

            BackendCheck.IsChecked = model.IsOn(Part.Backend);
            BackendCheck.IsEnabled = !model.BackendRequired;
            WebuiCheck.IsChecked = model.IsOn(Part.Webui);
            PluginCheck.IsChecked = model.IsOn(Part.Plugin);
            DatabaseCheck.IsChecked = model.IsOn(Part.Database);
            AudioCheck.IsChecked = model.Audio;
            AudioCheck.IsEnabled = model.Chosen.Contains(Part.Database);
            foreach (var pair in new[] { (BackendCard, Part.Backend), (WebuiCard, Part.Webui), (PluginCard, Part.Plugin), (DatabaseCard, Part.Database) })
                pair.Item1.BorderBrush = model.IsOn(pair.Item2) ? (Brush)FindResource("Accent") : (Brush)FindResource("CardBorder");

            Badges(BackendBadges, BadgesFor(Part.Backend));
            Badges(WebuiBadges, BadgesFor(Part.Webui));
            Badges(PluginBadges, BadgesFor(Part.Plugin));
            Badges(DatabaseBadges, DatabaseBadges_());
            News(BackendNews, Part.Backend);
            News(WebuiNews, Part.Webui);
            News(PluginNews, Part.Plugin);
            // The plugin alone does nothing: it talks to the backend services
            PluginWarning.Visibility = model.IsOn(Part.Plugin) && !model.BackendInstalled && !model.IsOn(Part.Backend) ? Visibility.Visible : Visibility.Collapsed;

            // Where the backend runs: a choice before the first installation, a fact afterwards
            var docker = Paths.DockerInstalled;
            BackendModeDocker.IsChecked = model.BackendMode == "docker";
            BackendModeLocal.IsChecked = model.BackendMode == "local";
            BackendModeDocker.IsEnabled = docker && !model.BackendInstalled;
            BackendModeLocal.IsEnabled = !model.BackendInstalled;
            BackendModeDockerText.Text = docker ? "In Docker Desktop: the services as containers, as on a Linux server."
                : "In Docker Desktop (not installed on this PC: docs.docker.com/desktop/setup/install/windows-install).";
            BackendModeNote.Visibility = model.BackendInstalled ? Visibility.Visible : Visibility.Collapsed;
            BackendModeNote.Text = model.BackendInstalled ? (model.InstalledBackendMode == "local" ? "Installed on this PC directly; an update keeps it so." : "Installed in Docker Desktop; an update keeps it so.") : "";
            OllamaPanel.Visibility = model.BackendMode == "docker" ? Visibility.Visible : Visibility.Collapsed;
            OllamaDocker.IsChecked = model.Ollama == "docker";
            OllamaHost.IsChecked = model.Ollama == "host";
            OllamaHostText.Text = Paths.OllamaInstalled ? "Ollama on this PC: the one that is installed already (found); it then also serves the spotting."
                : "Ollama on this PC: installed with winget if missing; it then also serves other programs.";

            WebuiModeDocker.IsChecked = model.WebuiMode == "docker";
            WebuiModeLocal.IsChecked = model.WebuiMode == "local";
            WebuiModeDocker.IsEnabled = docker && !model.WebuiInstalled && model.BackendMode == "docker";
            WebuiModeLocal.IsEnabled = !model.WebuiInstalled;
            WebuiModeNote.Visibility = model.WebuiInstalled || model.BackendMode == "local" ? Visibility.Visible : Visibility.Collapsed;
            WebuiModeNote.Text = model.WebuiInstalled ? (model.InstalledWebuiMode == "local" ? "Installed on this PC directly; an update keeps it so." : "Installed as a container; an update keeps it so.")
                : "With the services on this PC directly, the web UI is served the same way (set up by their installer).";

            var defaultData = Text.ShortPath(Path.Combine(Paths.Services, "data"));
            DataPath.Text = model.DataDir.Length > 0 ? Text.ShortPath(model.DataDir) : defaultData;
            DataPath.Foreground = model.DataDir.Length > 0 ? Brushes.Black : (Brush)FindResource("Secondary");
            DataChoose.IsEnabled = !model.BackendInstalled;
            DataDefault.Visibility = model.DataDir.Length > 0 && !model.BackendInstalled ? Visibility.Visible : Visibility.Hidden;
            DataHelp.Text = model.BackendInstalled ? "Set at the first installation." : "Database, models (about 22 GB) and downloaded audio (60 GB more with the full archive).";
            SessionsPath.Text = model.SessionsDir.Length > 0 ? Text.ShortPath(model.SessionsDir) : "<data folder>\\sessions";
            SessionsPath.Foreground = model.SessionsDir.Length > 0 ? Brushes.Black : (Brush)FindResource("Secondary");
            SessionsDefault.Visibility = model.SessionsDir.Length > 0 ? Visibility.Visible : Visibility.Hidden;
            BbcPath.Text = model.BbcArchive.Length > 0 ? Text.ShortPath(model.BbcArchive) : "None";
            BbcPath.Foreground = model.BbcArchive.Length > 0 ? Brushes.Black : (Brush)FindResource("Secondary");
            BbcDefault.Visibility = model.BbcArchive.Length > 0 ? Visibility.Visible : Visibility.Hidden;
            OwnPath.Text = model.OwnSounds.Length > 0 ? Text.ShortPath(model.OwnSounds) : "None";
            OwnPath.Foreground = model.OwnSounds.Length > 0 ? Brushes.Black : (Brush)FindResource("Secondary");
            OwnDefault.Visibility = model.OwnSounds.Length > 0 ? Visibility.Visible : Visibility.Hidden;

            Footer.Text = model.Checking > 0 ? "Looking for updates on GitHub…" : $"Installer {Text.InstallerVersion} · Windows 10 or 11, 64-bit, NVIDIA GPU";
            ActionButton.Content = model.ActionTitle;
            ActionButton.IsEnabled = model.Parts.Count > 0 && !model.SelfUpdating && File.Exists(Paths.Script);
        }

        string SubtitleText()
        {
            if (!model.AnyInstalled) return "Choose what to install on this PC.";
            if (model.Checking > 0) return "Looking for updates…";
            var updates = model.Updates;
            if (updates.Count == 0) return "Everything installed is up to date. Tick what you want to add.";
            return $"Updates are available for: {string.Join(", ", updates.Select(Model.Title))}. They are ticked.";
        }

        List<(string, Color)> BadgesFor(Part part)
        {
            var list = new List<(string, Color)>();
            if (part == Part.Backend && model.BackendRequired && !model.BackendInstalled) { list.Add(("Needed by your choice", Colors.DarkOrange)); return list; }
            string installed = null;
            switch (part)
            {
                case Part.Backend: installed = model.BackendInstalled ? (model.InstalledBackendMode == "local" ? "Installed on this PC" : "Installed in Docker") : null; break;
                case Part.Webui: installed = model.WebuiInstalled ? (model.InstalledWebuiMode == "local" ? "Installed on this PC" : "Installed in Docker") : null; break;
                case Part.Plugin: installed = model.PluginInstalled == null ? null : (model.PluginInstalled == "?" ? "Installed" : "Installed: " + model.PluginInstalled); break;
            }
            if (installed == null) { list.Add(("Not installed", Colors.Gray)); return list; }
            list.Add((installed, Colors.SeaGreen));
            var fresh = model.Fresh.ContainsKey(part) ? model.Fresh[part] : Freshness.Of(FreshnessKind.Unknown);
            switch (fresh.Kind)
            {
                case FreshnessKind.Checking: list.Add(("Checking…", Colors.Gray)); break;
                case FreshnessKind.UpToDate: list.Add(("Up to date", Colors.SeaGreen)); break;
                case FreshnessKind.Update: list.Add(("Update available", Color.FromRgb(0x3B, 0x5B, 0xDB))); break;
                case FreshnessKind.LocalChanges: list.Add(("Local changes", Colors.DarkOrange)); break;
                case FreshnessKind.Unknown: list.Add((fresh.Text ?? "Unknown", Colors.Gray)); break;
            }
            return list;
        }

        List<(string, Color)> DatabaseBadges_()
        {
            var list = new List<(string, Color)>();
            if (!model.BackendInstalled) return list;
            if (model.DatabaseLoading) list.Add(("Loading in the background", Color.FromRgb(0x3B, 0x5B, 0xDB)));
            else if (model.DatabaseSounds.HasValue && model.DatabaseSounds.Value > 0) list.Add(($"{model.DatabaseSounds.Value.ToString("N0", System.Globalization.CultureInfo.InvariantCulture)} sounds", Colors.SeaGreen));
            else if (model.DatabaseSounds.HasValue) list.Add(("Empty", Colors.Gray));
            else list.Add(("Services not answering", Colors.Gray));
            return list;
        }

        void Badges(StackPanel panel, List<(string, Color)> badges)
        {
            panel.Children.Clear();
            foreach (var badge in badges)
            {
                var color = badge.Item2;
                panel.Children.Add(new Border
                {
                    Style = (Style)FindResource("Badge"),
                    Background = new SolidColorBrush(Color.FromArgb(0x24, color.R, color.G, color.B)),
                    Child = new TextBlock { Text = badge.Item1, FontSize = 11, FontWeight = FontWeights.Medium, Foreground = new SolidColorBrush(color) }
                });
            }
        }

        void News(TextBlock block, Part part)
        {
            var fresh = model.Fresh.ContainsKey(part) ? model.Fresh[part] : Freshness.Of(FreshnessKind.Unknown);
            block.Visibility = fresh.Kind == FreshnessKind.Update ? Visibility.Visible : Visibility.Collapsed;
            block.Text = fresh.Kind == FreshnessKind.Update ? "↓ " + fresh.Text : "";
        }

        // Checked/Unchecked rather than Click: a screen reader or UI Automation toggles a
        // box without a click, and the render loop's own changes are guarded by `rendering`
        void CheckChanged(object sender, RoutedEventArgs e)
        {
            if (rendering) return;
            var box = (CheckBox)sender;
            Part part;
            if (Enum.TryParse((string)box.Tag, out part)) model.Set(part, box.IsChecked == true);
            e.Handled = true;
        }

        void CardClick(object sender, MouseButtonEventArgs e)
        {
            if (rendering) return;
            var source = e.OriginalSource as DependencyObject;
            // A click on a control inside the card is that control's
            while (source != null && source != sender)
            {
                if (source is CheckBox || source is RadioButton || source is Button || source is Expander) return;
                source = VisualTreeHelper.GetParent(source);
            }
            Part part;
            if (Enum.TryParse((string)((Border)sender).Tag, out part) && !(part == Part.Backend && model.BackendRequired))
                model.Set(part, !model.IsOn(part));
        }

        void SwallowClick(object sender, RoutedEventArgs e) { }

        void ModeChanged(object sender, RoutedEventArgs e)
        {
            if (rendering) return;
            if (sender == BackendModeDocker) model.BackendMode = "docker";
            else if (sender == BackendModeLocal) { model.BackendMode = "local"; model.Ollama = "host"; }
            else if (sender == OllamaDocker) model.Ollama = "docker";
            else if (sender == OllamaHost) model.Ollama = "host";
            else if (sender == WebuiModeDocker) model.WebuiMode = "docker";
            else if (sender == WebuiModeLocal) model.WebuiMode = "local";
            if (model.BackendMode == "local" && !model.WebuiInstalled) model.WebuiMode = "local";
            dirty = true;
        }

        void AudioChanged(object sender, RoutedEventArgs e)
        {
            if (rendering) return;
            model.Audio = AudioCheck.IsChecked == true;
            if (model.Audio) model.Set(Part.Database, true); else dirty = true;
            e.Handled = true;
        }

        void FolderClick(object sender, RoutedEventArgs e)
        {
            var tag = (string)((Button)sender).Tag;
            if (tag.EndsWith("-default"))
            {
                switch (tag) { case "data-default": model.DataDir = ""; break; case "sessions-default": model.SessionsDir = ""; break; case "bbc-default": model.BbcArchive = ""; break; default: model.OwnSounds = ""; break; }
                dirty = true;
                return;
            }
            var titles = new Dictionary<string, string> { ["data"] = "Data folder", ["sessions"] = "Folder with Pro Tools sessions", ["bbc"] = "Folder of an existing BBC archive", ["own"] = "Folder with your own sounds" };
            using (var dialog = new System.Windows.Forms.FolderBrowserDialog { Description = titles[tag], ShowNewFolderButton = tag == "data" })
            {
                if (dialog.ShowDialog() != System.Windows.Forms.DialogResult.OK) return;
                switch (tag) { case "data": model.DataDir = dialog.SelectedPath; break; case "sessions": model.SessionsDir = dialog.SelectedPath; break; case "bbc": model.BbcArchive = dialog.SelectedPath; break; default: model.OwnSounds = dialog.SelectedPath; break; }
            }
            dirty = true;
        }

        void UpdateInstallerClick(object sender, RoutedEventArgs e) => model.UpdateInstaller();

        void ActionClick(object sender, RoutedEventArgs e)
        {
            model.Start();
            logShown = -1;
            Render();
        }

        // ── running ───────────────────────────────────────────────────────────

        void RenderRun()
        {
            var running = model.Phase == Phase.Running;
            RunTitle.Text = model.Phase == Phase.Running ? (model.States.Keys.Any(p => p != Part.Database) ? "Installing" : "Loading the sound database")
                : model.Phase == Phase.Succeeded ? "Done" : "Not finished";
            RunSubtitle.Text = model.Phase == Phase.Running ? (model.InDatabasePhase ? "The sound database loads in the background: this window can be closed, the loading goes on." : "This can take a while; the details below show what is happening.")
                : model.Phase == Phase.Succeeded ? "Everything chosen is installed." + (model.States.ContainsKey(Part.Plugin) ? " If Pro Tools is open, quit and reopen it to load the new plugin." : "")
                : "The installation stopped. Try Again carries on where it stopped.";

            Steps.Children.Clear();
            foreach (var pair in model.States)
            {
                var glyph = pair.Value == RunState.Done ? "✓" : pair.Value == RunState.Running ? "●" : pair.Value == RunState.Failed ? "✕" : pair.Value == RunState.Skipped ? "–" : "○";
                var color = pair.Value == RunState.Done ? Colors.SeaGreen : pair.Value == RunState.Running ? Color.FromRgb(0x3B, 0x5B, 0xDB) : pair.Value == RunState.Failed ? Colors.Firebrick : Colors.Gray;
                var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 2, 0, 2) };
                row.Children.Add(new TextBlock { Text = glyph, Width = 22, Foreground = new SolidColorBrush(color), FontWeight = FontWeights.Bold });
                row.Children.Add(new TextBlock { Text = Model.Title(pair.Key), FontWeight = pair.Value == RunState.Running ? FontWeights.SemiBold : FontWeights.Normal });
                Steps.Children.Add(row);
            }
            StatusText.Text = model.Status;
            Bar.IsIndeterminate = running && model.Progress == null;
            Bar.Value = model.Progress ?? (model.Phase == Phase.Succeeded ? 1 : 0);
            Bar.Visibility = running || model.Phase == Phase.Succeeded ? Visibility.Visible : Visibility.Hidden;
            ErrorBox.Visibility = model.ErrorMessage != null && model.Phase == Phase.Failed ? Visibility.Visible : Visibility.Collapsed;
            ErrorText.Text = model.ErrorMessage ?? "";
            if (logShown != model.Log.Count || (model.Log.Count > 0 && LogBox.LineCount > 0 && LogBox.GetLineText(LogBox.LineCount - 1).TrimEnd() != model.Log[model.Log.Count - 1].TrimEnd()))
            {
                LogBox.Text = string.Join(Environment.NewLine, model.Log);
                LogBox.ScrollToEnd();
                logShown = model.Log.Count;
            }

            StopButton.Visibility = running ? Visibility.Visible : Visibility.Collapsed;
            CloseButton.Visibility = (running && model.InDatabasePhase) || model.Phase == Phase.Failed ? Visibility.Visible : Visibility.Collapsed;
            BackButton.Visibility = model.Phase == Phase.Failed ? Visibility.Visible : Visibility.Collapsed;
            RetryButton.Visibility = model.Phase == Phase.Failed ? Visibility.Visible : Visibility.Collapsed;
            DoneButton.Visibility = model.Phase == Phase.Succeeded ? Visibility.Visible : Visibility.Collapsed;
            ExplorerButton.Visibility = model.Phase == Phase.Succeeded ? Visibility.Visible : Visibility.Collapsed;
            SetupButton.Visibility = model.Phase == Phase.Succeeded && model.BackendInstalled ? Visibility.Visible : Visibility.Collapsed;
            WebuiButton.Visibility = model.Phase == Phase.Succeeded && model.WebuiInstalled ? Visibility.Visible : Visibility.Collapsed;
            RunFooter.Text = running ? "Windows may ask for permission (the plugin's setup, Node.js)." : model.Phase == Phase.Succeeded ? $"The installer is in {Text.ShortPath(Paths.InstalledDir)} and the Start menu, for updates later." : "";
        }

        void StopClick(object sender, RoutedEventArgs e)
        {
            if (MessageBox.Show("Stop the installation?\nWhat is half done is finished the next time.", "AI Sound Design Installer", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
                model.Stop();
        }

        void BackClick(object sender, RoutedEventArgs e) { model.Phase = Phase.Choose; model.Refresh(); Render(); }
        void CloseClick(object sender, RoutedEventArgs e) => Close();
        void ExplorerClick(object sender, RoutedEventArgs e) => Open(Paths.Home);
        void SetupClick(object sender, RoutedEventArgs e) => Open(model.SetupUrl);
        void WebuiClick(object sender, RoutedEventArgs e) => Open(model.WebuiUrl);

        static void Open(string target)
        {
            try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); } catch (Exception) { }
        }
    }
}
