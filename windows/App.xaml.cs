using System;
using System.Net;
using System.Windows;

namespace AiSoundDesign.Installer
{
    public partial class App : Application
    {
        protected override void OnStartup(StartupEventArgs e)
        {
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
            // A copy that replaced itself (the self-update) removes what it replaced
            try
            {
                var old = Paths.Exe + ".old";
                if (System.IO.File.Exists(old)) System.IO.File.Delete(old);
            }
            catch (Exception) { }
            base.OnStartup(e);
        }
    }
}
