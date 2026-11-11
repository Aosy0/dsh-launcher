using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32;

namespace DshLauncher;

/// <summary>A web app (PWA) installed in Brave, identified by its Chromium app id and profile.</summary>
internal sealed class BraveAppInfo
{
    public string AppId { get; set; } = "";
    public string ProfileDirectory { get; set; } = "";
    public string? Name { get; set; }
    public string Executable { get; set; } = "";

    /// <summary>The manifest id the app id was derived from (for diagnostics; not always known).</summary>
    public string? ManifestId { get; set; }

    public string Label => string.IsNullOrWhiteSpace(Name) ? AppId : Name!;

    /// <summary>The same command line the Start Menu shortcut in "Brave Apps" uses.</summary>
    public string CommandLine =>
        $"{Executable} --profile-directory=\"{ProfileDirectory}\" --app-id={AppId}";
}

internal sealed class BraveInstallation
{
    public string BraveExe { get; init; } = "";
    public string ProxyExe { get; init; } = "";
    public List<string> UserDataDirs { get; init; } = new();
}

/// <summary>
/// Opens this PC's DSH as the Brave web app (PWA) instead of a browser tab. This is a launcher-wide
/// action (bottom bar / tray), not attached to a machine row: the installed app belongs to one origin.
///
/// A Chromium web app is launched as <c>&lt;chrome_proxy.exe&gt; --profile-directory="Profile N" --app-id=&lt;id&gt;</c>,
/// which is exactly what the Start Menu shortcut under "Brave Apps" contains. The app id is derived from
/// the web app manifest id, so no shortcut parsing is needed: dsh serves <c>/manifest.webmanifest</c> with
/// <c>start_url: "./"</c>, which makes the id a hash of the page directory (the origin root by default).
/// </summary>
internal static class BraveApps
{
    private static readonly string[] Channels =
    {
        "Brave-Browser", "Brave-Browser-Beta", "Brave-Browser-Dev", "Brave-Browser-Nightly",
    };

    private static readonly TimeSpan CacheLifetime = TimeSpan.FromSeconds(30);
    private static readonly object Gate = new();
    private static readonly Dictionary<string, (BraveAppInfo? App, DateTime At)> Cache = new(StringComparer.OrdinalIgnoreCase);

    private static readonly object InstallGate = new();
    private static List<BraveInstallation>? _installations;
    private static bool _installationsChecked;
    private static DateTime _installationsAt;

    /// <summary>The Brave app installed for this machine's URL, or null when there is none.</summary>
    public static BraveAppInfo? Find(Machine machine)
    {
        // An ssh machine without url falls back to 127.0.0.1 in Machine.TargetUrl, which would match
        // this PC's PWA: never resolve a remote machine to the local app.
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

    public static BraveAppInfo? FindForUrl(string url)
    {
        var now = DateTime.UtcNow;
        lock (Gate)
        {
            if (Cache.TryGetValue(url, out var cached) && now - cached.At < CacheLifetime) return cached.App;
        }

        BraveAppInfo? result = null;
        try { result = Detect(url); }
        catch { /* detection is best-effort */ }

        lock (Gate) { Cache[url] = (result, now); }
        return result;
    }

    private static BraveAppInfo? Detect(string url)
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

    private static BraveAppInfo? ScanProfiles(BraveInstallation installation, string appId)
    {
        foreach (var userData in installation.UserDataDirs)
        {
            foreach (var profile in Profiles(userData))
            {
                var webApps = Path.Combine(profile, "Web Applications");
                var iconDir = Path.Combine(webApps, "_crx_" + appId);
                var manifestDir = Path.Combine(webApps, "Manifest Resources", appId);
                if (!Directory.Exists(iconDir) && !Directory.Exists(manifestDir)) continue;
                return new BraveAppInfo
                {
                    AppId = appId,
                    ProfileDirectory = Path.GetFileName(profile),
                    Name = NameFor(iconDir),
                    Executable = installation.ProxyExe,
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

    /// <summary>Launch the installed app. Launches are the same as clicking its Start Menu shortcut.</summary>
    public static (bool Ok, string Message) Launch(BraveAppInfo app)
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

    /// <summary>Open the URL as a normal Brave tab (used to install the app when it is missing).</summary>
    public static (bool Ok, string Message) OpenInBrave(string url)
    {
        var installation = Installations().FirstOrDefault();
        if (installation is null) return (false, "Brave が見つかりません");
        try
        {
            Process.Start(new ProcessStartInfo(installation.BraveExe, url) { UseShellExecute = true });
            return (true, $"opened {url}");
        }
        catch (Exception error)
        {
            return (false, error.Message);
        }
    }

    /// <summary>Every Brave install (stable, beta, dev, nightly) together with the user data dirs it owns.</summary>
    public static List<BraveInstallation> Installations()
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

    private static List<BraveInstallation> FindInstallations()
    {
        var installations = new List<BraveInstallation>();
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

        foreach (var exe in BraveExecutables())
        {
            var appDir = Path.GetDirectoryName(exe);
            if (string.IsNullOrEmpty(appDir)) continue;
            var channelDir = Path.GetDirectoryName(appDir);
            if (string.IsNullOrEmpty(channelDir)) continue;
            var channel = Path.GetFileName(channelDir);

            // Profiles belong to the channel: the install owns <channel>\User Data, and the same
            // channel directory under LocalAppData when the exe lives elsewhere.
            var userDataDirs = new List<string>();
            AddUserDataDir(userDataDirs, Path.GetFullPath(Path.Combine(channelDir, "User Data")));
            AddUserDataDir(userDataDirs, Path.Combine(local, "BraveSoftware", channel, "User Data"));

            var proxy = Path.Combine(appDir, "chrome_proxy.exe");
            installations.Add(new BraveInstallation
            {
                BraveExe = exe,
                ProxyExe = File.Exists(proxy) ? proxy : exe,
                UserDataDirs = userDataDirs,
            });
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

    private static IEnumerable<string> BraveExecutables()
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var exe in RegistryCandidates().Concat(FileCandidates()))
        {
            if (string.IsNullOrWhiteSpace(exe)) continue;
            string full;
            try { full = Path.GetFullPath(exe); }
            catch { continue; }
            if (!File.Exists(full) || !seen.Add(full)) continue;
            yield return full;
        }
    }

    private static IEnumerable<string> RegistryCandidates()
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
                using var key = baseKey.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\brave.exe");
                value = key?.GetValue(null) as string;
            }
            catch { /* registry is optional */ }
            if (!string.IsNullOrWhiteSpace(value)) yield return value.Trim('"');
        }
    }

    private static IEnumerable<string> FileCandidates()
    {
        var roots = new List<string>
        {
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        };
        foreach (var root in roots.Where(root => !string.IsNullOrWhiteSpace(root)))
        {
            foreach (var channel in Channels)
                yield return Path.Combine(root, "BraveSoftware", channel, "Application", "brave.exe");
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
