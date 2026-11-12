using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32;

namespace DshLauncher;

/// <summary>A web app (PWA) installed in a Chromium-based browser, identified by app id and profile.</summary>
internal sealed class BrowserAppInfo
{
    public string AppId { get; set; } = "";
    public string ProfileDirectory { get; set; } = "";
    public string? Name { get; set; }
    public string Executable { get; set; } = "";
    public string BrowserExe { get; set; } = "";
    public string Browser { get; set; } = "";

    /// <summary>The manifest id the app id was derived from (for diagnostics; not always known).</summary>
    public string? ManifestId { get; set; }

    public string Label => string.IsNullOrWhiteSpace(Name) ? AppId : Name!;

    /// <summary>The same command line the browser's app shortcut uses.</summary>
    public string CommandLine =>
        $"{Executable} --profile-directory=\"{ProfileDirectory}\" --app-id={AppId}";
}

internal sealed class BrowserInstallation
{
    public string Label { get; init; } = "";
    public string BrowserExe { get; init; } = "";
    public string LaunchExe { get; init; } = "";
    public List<string> UserDataDirs { get; init; } = new();
}

/// <summary>
/// Opens this PC's DSH as an installed web app (PWA) in whichever Chromium-based browser has it.
/// This is a launcher-wide action (bottom bar / tray), not attached to a machine row.
///
/// Chromium-family browsers store installed web apps as <c>&lt;User Data&gt;\&lt;Profile&gt;\Web Applications\_crx_&lt;id&gt;</c>
/// and launch them with <c>&lt;browser proxy&gt; --profile-directory="Profile N" --app-id=&lt;id&gt;</c>.
/// The app id is derived from the web app manifest id, so no shortcut parsing is needed: dsh serves
/// <c>/manifest.webmanifest</c> with <c>start_url: "./"</c>, which makes the id a hash of the page directory.
/// Supported browsers: Chrome / Edge / Brave / Chromium (Firefox-style browsers cannot install Web Apps).
/// </summary>
internal static class BrowserApps
{
    private static readonly TimeSpan CacheLifetime = TimeSpan.FromSeconds(30);
    private static readonly object Gate = new();
    private static readonly Dictionary<string, (BrowserAppInfo? App, DateTime At)> Cache = new(StringComparer.OrdinalIgnoreCase);

    private static readonly object InstallGate = new();
    private static List<BrowserInstallation>? _installations;
    private static bool _installationsChecked;
    private static DateTime _installationsAt;

    /// <summary>The installed web app for this machine's URL, or null when there is none.</summary>
    public static BrowserAppInfo? Find(Machine machine)
    {
        // An ssh machine without url falls back to 127.0.0.1 in Machine.TargetUrl, which would match
        // this PC's app: never resolve a remote machine to the local one.
        if (machine.Kind == MachineKind.Ssh && string.IsNullOrWhiteSpace(machine.Url)) return null;

        var found = FindForUrl(machine.TargetUrl);
        if (found is not null) return found;
        if (machine.Kind != MachineKind.Local) return null;

        // The local DSH may have been installed from either loopback spelling.
        foreach (var fallback in new[] { $"http://127.0.0.1:{machine.Port}/", $"http://localhost:{machine.Port}/" })
        {
            found = FindForUrl(fallback);
            if (found is not null) return found;
        }
        return null;
    }

    public static BrowserAppInfo? FindForUrl(string url)
    {
        var now = DateTime.UtcNow;
        lock (Gate)
        {
            if (Cache.TryGetValue(url, out var cached) && now - cached.At < CacheLifetime) return cached.App;
        }

        BrowserAppInfo? result = null;
        try { result = Detect(url); }
        catch { /* detection is best-effort */ }

        lock (Gate) { Cache[url] = (result, now); }
        return result;
    }

    private static BrowserAppInfo? Detect(string url)
    {
        var installations = Installations();
        if (installations.Count == 0) return null;

        foreach (var manifestId in Candidates(url))
        {
            var appId = AppIdForManifestId(manifestId);
            foreach (var installation in installations)
            {
                var hit = ScanProfiles(installation, appId);
                if (hit is null) continue;
                hit.ManifestId = manifestId;
                return hit;
            }
        }
        return null;
    }

    /// <summary>Manifest id candidates, most specific first. dsh's start_url is "./".</summary>
    private static IEnumerable<string> Candidates(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) yield break;
        if (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps) yield break;

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var origin = $"{uri.Scheme}://{uri.Authority}";
        var path = string.IsNullOrEmpty(uri.AbsolutePath) ? "/" : uri.AbsolutePath;
        var page = origin + (path.EndsWith("/", StringComparison.Ordinal) ? path : path + "/");
        if (seen.Add(page)) yield return page;

        var root = origin + "/";
        if (seen.Add(root)) yield return root;
    }

    private static BrowserAppInfo? ScanProfiles(BrowserInstallation installation, string appId)
    {
        foreach (var userData in installation.UserDataDirs)
        {
            foreach (var profile in Profiles(userData))
            {
                var webApps = Path.Combine(profile, "Web Applications");
                // Edge names its app icon folder "_crx__<id>" (extra underscore), Chrome uses "_crx_<id>".
                var iconDir = new[] { Path.Combine(webApps, "_crx_" + appId), Path.Combine(webApps, "_crx__" + appId) }
                    .FirstOrDefault(Directory.Exists);
                var manifestDir = Path.Combine(webApps, "Manifest Resources", appId);
                if (iconDir is null && !Directory.Exists(manifestDir)) continue;
                return new BrowserAppInfo
                {
                    AppId = appId,
                    ProfileDirectory = Path.GetFileName(profile),
                    Name = iconDir is null ? null : NameFor(iconDir),
                    Executable = installation.LaunchExe,
                    BrowserExe = installation.BrowserExe,
                    Browser = installation.Label,
                };
            }
        }
        return null;
    }

    /// <summary>
    /// Chromium's web app id: the a-p alphabet encoding of the first 16 bytes of
    /// SHA256(SHA256(manifest id)) — the hash is applied twice for historical reasons.
    /// </summary>
    public static string AppIdForManifestId(string manifestId)
    {
        var inner = SHA256.HashData(Encoding.UTF8.GetBytes(manifestId));
        var outer = SHA256.HashData(inner);
        var chars = new char[32];
        for (var i = 0; i < 16; i++)
        {
            chars[i * 2] = (char)('a' + (outer[i] >> 4));
            chars[i * 2 + 1] = (char)('a' + (outer[i] & 0xF));
        }
        return new string(chars);
    }

    /// <summary>Launch the installed app: the same command line as the browser's app shortcut.</summary>
    public static (bool Ok, string Message) Launch(BrowserAppInfo app)
    {
        try
        {
            var psi = new ProcessStartInfo(app.Executable, $"--profile-directory=\"{app.ProfileDirectory}\" --app-id={app.AppId}")
            {
                UseShellExecute = true,
                WorkingDirectory = Path.GetDirectoryName(app.Executable) ?? "",
            };
            Process.Start(psi);
            return (true, $"opened {app.Label}");
        }
        catch (Exception error)
        {
            return (false, error.Message);
        }
    }

    /// <summary>Open the URL in the default browser (install guidance when no app is installed).</summary>
    public static (bool Ok, string Message) OpenInBrowser(string url)
    {
        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
            return (true, $"opened {url}");
        }
        catch (Exception error)
        {
            return (false, error.Message);
        }
    }

    /// <summary>Chromium-based browsers installed on this PC, together with the user data dirs they own.</summary>
    public static List<BrowserInstallation> Installations()
    {
        lock (InstallGate)
        {
            var now = DateTime.UtcNow;
            if (_installationsChecked && now - _installationsAt < TimeSpan.FromSeconds(60)) return _installations!;
            _installationsChecked = true;
            _installationsAt = now;
            _installations = FindInstallations();
            return _installations;
        }
    }

    private static List<BrowserInstallation> FindInstallations()
    {
        var installations = new List<BrowserInstallation>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var roots = new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            local,
        }.Where(root => !string.IsNullOrWhiteSpace(root)).ToArray();

        void Add(string label, string[] registryNames, string installRelative, string userDataRelative, string[] proxyNames)
        {
            var candidates = new List<string>();
            foreach (var name in registryNames) candidates.AddRange(RegistryCandidates(name));
            foreach (var root in roots) candidates.Add(Path.Combine(root, installRelative));

            foreach (var candidate in candidates)
            {
                string exe;
                try { exe = Path.GetFullPath(candidate); } catch { continue; }
                if (!File.Exists(exe) || !seen.Add(exe)) continue;

                var appDir = Path.GetDirectoryName(exe);
                if (string.IsNullOrEmpty(appDir)) continue;

                var userDataDirs = new List<string>();
                var channelDir = Path.GetDirectoryName(appDir);
                if (!string.IsNullOrEmpty(channelDir)) AddUserDataDir(userDataDirs, Path.Combine(channelDir, "User Data"));
                AddUserDataDir(userDataDirs, Path.Combine(local, userDataRelative));
                if (userDataDirs.Count == 0) continue;

                var launchExe = proxyNames
                    .Select(proxy => Path.Combine(appDir, proxy))
                    .FirstOrDefault(File.Exists) ?? exe;
                installations.Add(new BrowserInstallation
                {
                    Label = label,
                    BrowserExe = exe,
                    LaunchExe = launchExe,
                    UserDataDirs = userDataDirs,
                });
            }
        }

        Add("Chrome", new[] { "chrome.exe" }, @"Google\Chrome\Application\chrome.exe", @"Google\Chrome\User Data", new[] { "chrome_proxy.exe" });
        Add("Edge", new[] { "msedge.exe" }, @"Microsoft\Edge\Application\msedge.exe", @"Microsoft\Edge\User Data", new[] { "msedge_proxy.exe" });
        Add("Chromium", new[] { "chrome.exe" }, @"Chromium\Application\chrome.exe", @"Chromium\User Data", new[] { "chrome_proxy.exe" });
        foreach (var (label, channel) in new[]
        {
            ("Brave", "Brave-Browser"),
            ("Brave Beta", "Brave-Browser-Beta"),
            ("Brave Dev", "Brave-Browser-Dev"),
            ("Brave Nightly", "Brave-Browser-Nightly"),
        })
        {
            Add(label, new[] { "brave.exe" }, $@"BraveSoftware\{channel}\Application\brave.exe", $@"BraveSoftware\{channel}\User Data", new[] { "chrome_proxy.exe" });
        }

        return installations;
    }

    private static void AddUserDataDir(List<string> dirs, string candidate)
    {
        try
        {
            if (!File.Exists(Path.Combine(candidate, "Local State"))) return;
            if (dirs.Contains(candidate, StringComparer.OrdinalIgnoreCase)) return;
            dirs.Add(candidate);
        }
        catch { /* invalid path: skip */ }
    }

    private static IEnumerable<string> RegistryCandidates(string exeName)
    {
        var entries = new (RegistryHive Hive, RegistryView View)[]
        {
            (RegistryHive.CurrentUser, RegistryView.Default),
            (RegistryHive.LocalMachine, RegistryView.Registry64),
            (RegistryHive.LocalMachine, RegistryView.Registry32),
        };
        foreach (var (hive, view) in entries)
        {
            string? value = null;
            try
            {
                using var baseKey = RegistryKey.OpenBaseKey(hive, view);
                using var key = baseKey.OpenSubKey($@"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\{exeName}");
                value = key?.GetValue(null) as string;
            }
            catch { /* registry is optional */ }
            if (!string.IsNullOrWhiteSpace(value)) yield return value.Trim('"');
        }
    }

    private static IEnumerable<string> Profiles(string userDataDir)
    {
        var profiles = new List<string>();

        var def = Path.Combine(userDataDir, "Default");
        if (File.Exists(Path.Combine(def, "Preferences"))) profiles.Add(def);

        try
        {
            var numbered = Directory.EnumerateDirectories(userDataDir, "Profile *")
                .Select(dir => (Dir: dir, Number: ProfileNumber(Path.GetFileName(dir))))
                .Where(x => x.Number is not null)
                .OrderBy(x => x.Number)
                .Select(x => x.Dir);
            foreach (var dir in numbered)
            {
                if (File.Exists(Path.Combine(dir, "Preferences"))) profiles.Add(dir);
            }
        }
        catch { /* best-effort */ }

        return profiles;
    }

    private static int? ProfileNumber(string name)
    {
        var digits = new string(name.Where(char.IsDigit).ToArray());
        return int.TryParse(digits, out var value) ? value : null;
    }

    private static string? NameFor(string iconDir)
    {
        try
        {
            if (!Directory.Exists(iconDir)) return null;
            var icon = Directory.EnumerateFiles(iconDir, "*.ico").FirstOrDefault();
            var name = icon is null ? null : Path.GetFileNameWithoutExtension(icon);
            return string.IsNullOrWhiteSpace(name) ? null : name;
        }
        catch
        {
            return null;
        }
    }
}
