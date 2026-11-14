using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace DshLauncher;

internal sealed class DshVersionInfo
{
    /// <summary>Version of the DSH that the local machine runs; null when it cannot be read.</summary>
    public string? Current { get; init; }

    /// <summary>`latest` dist-tag of @deepseek-ai/dsh on the npm registry; null when the check failed.</summary>
    public string? Latest { get; init; }

    public bool IsNewer { get; init; }

    public string? Error { get; init; }
}

/// <summary>
/// DSH itself (the `@deepseek-ai/dsh` npm package), not the launcher exe: the launcher reads the
/// installed version from the package next to the dsh shim it starts, compares it with the registry's
/// `latest` dist-tag, and updates by stopping the local DSH, running `npm install -g`, then starting it
/// again when it was running before. Only the local machine is handled — remote machines keep the
/// existing `setup --install` flow because their npm prefix differs per host.
/// </summary>
internal static class DshUpdates
{
    public const string Package = "@deepseek-ai/dsh";
    public const string Channel = "latest";

    /// <summary>How long an installed version stays cached in memory.</summary>
    private static readonly TimeSpan VersionCache = TimeSpan.FromMinutes(5);

    private static readonly HttpClient Http = CreateClient();
    private static readonly object Gate = new();

    private static string? _version;
    private static DateTime _checkedAt = DateTime.MinValue;

    public static string RegistryUrl => $"https://registry.npmjs.org/{Package}/{Channel}";

    /// <summary>Last version read by <see cref="LocalVersion"/>; null until the first read.</summary>
    public static string? CachedVersion
    {
        get { lock (Gate) return _version; }
    }

    /// <summary>The version of the dsh the launcher starts, cached for a few minutes.</summary>
    public static string? LocalVersion(bool refresh = false)
    {
        lock (Gate)
        {
            if (!refresh && _version is not null && (DateTime.UtcNow - _checkedAt) < VersionCache) return _version;
            _version = ReadInstalledVersion();
            _checkedAt = DateTime.UtcNow;
            return _version;
        }
    }

    private static string? ReadInstalledVersion()
    {
        var shim = Local.DshCommand();

        // The npm shim sits next to node_modules, so the package metadata is authoritative and
        // avoids spawning node (about a second) on every refresh.
        if (Path.IsPathRooted(shim))
        {
            var directory = Path.GetDirectoryName(shim);
            if (directory is not null)
            {
                var package = Path.Combine(directory, "node_modules", "@deepseek-ai", "dsh", "package.json");
                var fromDisk = ReadPackageVersion(package);
                if (fromDisk is not null) return fromDisk;
            }
        }

        return QueryVersion(shim);
    }

    private static string? ReadPackageVersion(string path)
    {
        try
        {
            if (!File.Exists(path)) return null;
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            return document.RootElement.TryGetProperty("version", out var version) ? version.GetString() : null;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>Fallback for a dsh that is only reachable through PATH.</summary>
    private static string? QueryVersion(string shim)
    {
        var (exit, output) = RunCapture("cmd.exe", $"/d /c \"\"{shim}\" --version\"", 20_000);
        if (exit != 0) return null;
        foreach (var raw in output.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length > 0 && (char.IsDigit(line[0]) || line[0] is 'v' or 'V')) return line.TrimStart('v', 'V');
        }
        return null;
    }

    /// <summary>Latest published version (`latest` dist-tag), or null when the registry is unreachable.</summary>
    public static async Task<string?> LatestAsync()
    {
#if DEBUG
        // Laboratory seam (debug builds only): lets the UI test the badge without waiting for a release.
        var overridden = Environment.GetEnvironmentVariable("DSHL_DSH_LATEST");
        if (!string.IsNullOrWhiteSpace(overridden)) return overridden.Trim();
#endif
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, RegistryUrl);
            request.Headers.TryAddWithoutValidation("Accept", "application/json");
            using var response = await Http.SendAsync(request);
            if (!response.IsSuccessStatusCode) return null;
            using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            return document.RootElement.TryGetProperty("version", out var version) ? version.GetString() : null;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>Installed and latest versions together, with the comparison and a readable error.</summary>
    public static async Task<DshVersionInfo> CheckAsync()
    {
        var current = await Task.Run(() => LocalVersion());
        var latest = await LatestAsync();
        var newer = current is not null && latest is not null && Compare(latest, current) > 0;
        var error = current is null
            ? "インストール済みの DSH バージョンを確認できませんでした。"
            : latest is null
                ? "最新バージョンを確認できませんでした（npm レジストリに接続できません）。"
                : null;
        return new DshVersionInfo { Current = current, Latest = latest, IsNewer = newer, Error = error };
    }

    /// <summary>The npm executable used for the global install.</summary>
    public static string NpmPath()
    {
#if DEBUG
        // Laboratory seam (debug builds only): a stub npm lets tests exercise stop/install/start.
        var overridden = Environment.GetEnvironmentVariable("DSHL_DSH_NPM");
        if (!string.IsNullOrWhiteSpace(overridden)) return overridden.Trim();
#endif
        var candidates = new[]
        {
            Path.Combine(Environment.GetEnvironmentVariable("ProgramFiles") ?? "", "nodejs", "npm.cmd"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "nodejs", "npm.cmd"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm", "npm.cmd"),
        };
        foreach (var candidate in candidates)
        {
            if (candidate.Length > 0 && File.Exists(candidate)) return candidate;
        }

        var (exit, output) = RunCapture("cmd.exe", "/d /c \"where npm\"", 10_000);
        if (exit == 0)
        {
            var found = output.Split('\n')
                .Select(line => line.Trim())
                .FirstOrDefault(line => line.EndsWith("npm.cmd", StringComparison.OrdinalIgnoreCase));
            if (found is not null && File.Exists(found)) return found;
        }
        return "npm";
    }

    /// <summary>Human-readable install command, used in confirmation receipts and CLI plans.</summary>
    public static string InstallCommandLine(string version) => $"npm install -g {Package}@{version}";

    /// <summary>Local update log; the npm transcript goes here for troubleshooting.</summary>
    public static string LogPath
    {
        get
        {
            var directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "DshLauncher", "logs");
            Directory.CreateDirectory(directory);
            return Path.Combine(directory, "dsh-update.log");
        }
    }

    /// <summary>
    /// Stops the local DSH when it is running, installs the exact version (pinned, so the result is
    /// reproducible), verifies it, and starts DSH again when it was running before. Failures restart
    /// the previous version so the machine is never left stopped without a reason in the message.
    /// </summary>
    public static async Task<(bool Ok, string Message)> InstallAsync(
        Machine machine, string version, Action<string>? progress = null)
    {
        var wasRunning = Ports.ListenerPid(machine.Port) is not null;
        if (wasRunning)
        {
            progress?.Invoke("停止しています");
            var stop = await Local.StopAsync(machine);
            if (!stop.Ok)
            {
                return (false, $"停止に失敗したため更新しませんでした（{stop.Message}）。");
            }
        }

        progress?.Invoke($"{version} をインストールしています");
        var npm = NpmPath();
        var spec = $"{Package}@{version}";
        var arguments = NpmArguments(npm, $"install -g {spec}");
        AppendLog($"=== {DateTime.Now:yyyy-MM-dd HH:mm:ss} {InstallCommandLine(version)} (npm: {npm})");
        var (exit, output) = await Task.Run(() => RunCapture("cmd.exe", arguments, 600_000));
        AppendLog(output.TrimEnd());
        AppendLog($"=== exit {exit}");

        if (exit != 0)
        {
            if (wasRunning) await Local.StartAsync(machine);
            var tail = Tail(output, 6);
            var detail = tail.Length == 0 ? "" : "\n" + tail;
            return (false,
                $"npm install に失敗しました（終了コード {exit}）。{(wasRunning ? "元のバージョンで起動し直しました。" : "")}{detail}");
        }

        var installed = LocalVersion(refresh: true);
        if (wasRunning)
        {
            progress?.Invoke("起動しています");
            var start = await Local.StartAsync(machine);
            if (!start.Ok)
            {
                return (false, $"DSH {installed ?? version} に更新しましたが、起動に失敗しました（{start.Message}）。");
            }
        }

        if (installed is null)
        {
            return (true, $"DSH {version} に更新しました（バージョンは確認できませんでした）。");
        }
        if (!VersionEquals(installed, version))
        {
            return (false,
                $"npm install は成功しましたが、dsh --version は {installed} のままです。" +
                $"別の場所の dsh が優先されている可能性があります（{InstallCommandLine(version)}）。");
        }
        return (true, $"DSH {installed} に更新しました。{(wasRunning ? "起動し直しています。" : "")}");
    }

    private static string NpmArguments(string npm, string rest)
    {
        // cmd.exe needs the executable quoted inside the /c command string; a bare name is left alone
        // so that PATH resolution keeps working.
        return Path.IsPathRooted(npm) || npm.Contains(' ')
            ? $"/d /c \"\"{npm}\" {rest}\""
            : $"/d /c \"{npm} {rest}\"";
    }

    private static (int Exit, string Output) RunCapture(string file, string arguments, int timeoutMs)
    {
        try
        {
            var psi = new ProcessStartInfo(file, arguments)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };
            using var process = Process.Start(psi);
            if (process is null) return (-1, "failed to start " + file);
            var stdout = process.StandardOutput.ReadToEndAsync();
            var stderr = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(timeoutMs))
            {
                try { process.Kill(true); } catch { /* already gone */ }
                return (-2, $"timeout after {timeoutMs / 1000}s");
            }
            process.WaitForExit();
            return (process.ExitCode, stdout.GetAwaiter().GetResult() + stderr.GetAwaiter().GetResult());
        }
        catch (Exception error)
        {
            return (-1, error.Message);
        }
    }

    private static void AppendLog(string text)
    {
        try
        {
            File.AppendAllText(LogPath, text + Environment.NewLine, new UTF8Encoding(false));
        }
        catch
        {
            // The transcript is a diagnostic aid; an unwritable log never blocks the update.
        }
    }

    private static string Tail(string text, int lines)
    {
        var all = text.Replace("\r", "").Split('\n', StringSplitOptions.RemoveEmptyEntries);
        if (all.Length == 0) return "";
        return string.Join("\n", all.Skip(Math.Max(0, all.Length - lines)).Select(line => line.TrimEnd()));
    }

    /// <summary>Semver comparison (prerelease ordering included): positive when <paramref name="left"/> is newer.</summary>
    public static int Compare(string? left, string? right)
    {
        if (string.IsNullOrWhiteSpace(left) || string.IsNullOrWhiteSpace(right)) return 0;
        var a = SplitVersion(left);
        var b = SplitVersion(right);
        var core = CompareCore(a.Core, b.Core);
        if (core != 0) return core;
        if (a.Pre.Length == 0 && b.Pre.Length == 0) return 0;
        if (a.Pre.Length == 0) return 1;
        if (b.Pre.Length == 0) return -1;
        return ComparePrerelease(a.Pre, b.Pre);
    }

    public static bool VersionEquals(string? left, string? right) =>
        !string.IsNullOrWhiteSpace(left) && Compare(left, right) == 0;

    private static (int[] Core, string[] Pre) SplitVersion(string text)
    {
        var value = text.Trim().TrimStart('v', 'V');
        var plus = value.IndexOf('+');
        if (plus >= 0) value = value[..plus];
        var dash = value.IndexOf('-');
        var coreText = dash >= 0 ? value[..dash] : value;
        var preText = dash >= 0 ? value[(dash + 1)..] : "";
        var core = coreText.Split('.')
            .Select(part => int.TryParse(part, out var number) ? number : 0)
            .ToArray();
        var pre = preText.Length == 0 ? Array.Empty<string>() : preText.Split('.');
        return (core, pre);
    }

    private static int CompareCore(int[] left, int[] right)
    {
        var length = Math.Max(left.Length, right.Length);
        for (var i = 0; i < length; i++)
        {
            var a = i < left.Length ? left[i] : 0;
            var b = i < right.Length ? right[i] : 0;
            if (a != b) return a.CompareTo(b);
        }
        return 0;
    }

    private static int ComparePrerelease(string[] left, string[] right)
    {
        var length = Math.Max(left.Length, right.Length);
        for (var i = 0; i < length; i++)
        {
            if (i >= left.Length) return -1;
            if (i >= right.Length) return 1;
            var hasNumber = int.TryParse(left[i], out var a);
            var hasOtherNumber = int.TryParse(right[i], out var b);
            if (hasNumber && hasOtherNumber)
            {
                if (a != b) return a.CompareTo(b);
            }
            else if (hasNumber)
            {
                return -1;
            }
            else if (hasOtherNumber)
            {
                return 1;
            }
            else
            {
                var compared = string.CompareOrdinal(left[i], right[i]);
                if (compared != 0) return compared;
            }
        }
        return 0;
    }

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        client.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", "dshl-dsh-updater");
        return client;
    }
}
