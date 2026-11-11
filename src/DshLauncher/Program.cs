using System.IO;
using System.Threading;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Text;

namespace DshLauncher;

/// <summary>Product identity shared by the window, the tray tooltip, and the CLI.</summary>
internal static class AppInfo
{
    public static string Version { get; } =
        "v" + (typeof(AppInfo).Assembly.GetName().Version?.ToString(3) ?? "0.1.0");
}

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length > 0 && !args[0].Equals("gui", StringComparison.OrdinalIgnoreCase))
        {
            ConsoleBridge.Init();
            return Cli.Run(args);
        }

        string? configPath = null;
        for (var i = 0; i < args.Length; i++)
        {
            if (args[i] == "--config" && i + 1 < args.Length) configPath = args[i + 1];
        }
        var app = new Ui.DshApplication(configPath);
        return app.Run();
    }
}

/// <summary>WinExe has no console of its own: attach to the launching terminal when possible.</summary>
internal static class ConsoleBridge
{
    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(int processId);

    private static bool _initialized;

    public static void Init()
    {
        if (_initialized) return;
        _initialized = true;
        try { AttachConsole(-1); } catch { /* no parent console */ }
        try
        {
            Console.OutputEncoding = Encoding.UTF8;
            Console.SetOut(new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true });
            Console.SetError(new StreamWriter(Console.OpenStandardError(), new UTF8Encoding(false)) { AutoFlush = true });
        }
        catch
        {
            // No usable standard handles: keep the default writers and fail silently.
        }
    }
}


