using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace DshLauncher;

internal sealed class UpdateInfo
{
    public string Version { get; init; } = "";
    public string Tag { get; init; } = "";
    public string AssetName { get; init; } = "";
    public string AssetUrl { get; init; } = "";
    public string? SumsUrl { get; init; }
    public string Notes { get; init; } = "";
    public bool IsNewer { get; init; }
    public long AssetSize { get; init; }
}

/// <summary>
/// In-app updates from GitHub Releases. Checks the latest release, downloads the same executable
/// flavour that is currently running (self-contained or framework-dependent), verifies the release
/// SHA-256, and replaces the running exe through a small detached PowerShell helper that waits for
/// this process to exit and then relaunches the new build.
/// </summary>
internal static class Updater
{
    private const string Repo = "Aosy0/dsh-launcher";
    private const string UserAgent = "dshl-updater";
    private static readonly HttpClient Http = CreateClient();

    public static string CurrentVersion => AppInfo.Version.TrimStart('v');

    public static string? CurrentExePath => Environment.ProcessPath;

    /// <summary>Latest release (stable) or null when the check failed.</summary>
    public static async Task<UpdateInfo?> CheckAsync()
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, $"https://api.github.com/repos/{Repo}/releases/latest");
            request.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
            request.Headers.TryAddWithoutValidation("Accept", "application/vnd.github+json");
            using var response = await Http.SendAsync(request);
            if (!response.IsSuccessStatusCode) return null;

            var json = await response.Content.ReadAsStringAsync();
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            var tag = root.TryGetProperty("tag_name", out var tagElement) ? tagElement.GetString() ?? "" : "";
            var versionText = tag.TrimStart('v', 'V');
            if (!Version.TryParse(versionText, out var latest)) return null;
            if (!Version.TryParse(CurrentVersion, out var current)) return null;

            var notes = root.TryGetProperty("body", out var bodyElement) ? bodyElement.GetString() ?? "" : "";
            var assets = new List<(string Name, string Url, long Size)>();
            if (root.TryGetProperty("assets", out var assetsElement))
            {
                foreach (var asset in assetsElement.EnumerateArray())
                {
                    var name = asset.TryGetProperty("name", out var nameElement) ? nameElement.GetString() ?? "" : "";
                    var url = asset.TryGetProperty("browser_download_url", out var urlElement) ? urlElement.GetString() ?? "" : "";
                    var size = asset.TryGetProperty("size", out var sizeElement) ? sizeElement.GetInt64() : 0;
                    if (name.Length > 0 && url.Length > 0) assets.Add((name, url, size));
                }
            }

            var selfContained = IsSelfContained(CurrentExePath);
            var preferred = selfContained
                ? $"dshl-{versionText}-win-x64.exe"
                : $"dshl-{versionText}-win-x64-framework-dependent.exe";
            var fallback = selfContained
                ? $"dshl-{versionText}-win-x64-framework-dependent.exe"
                : $"dshl-{versionText}-win-x64.exe";
            var chosen = assets.FirstOrDefault(asset => asset.Name == preferred);
            if (chosen.Name is null) chosen = assets.FirstOrDefault(asset => asset.Name == fallback);
            if (chosen.Name is null) return null;

            var sums = assets.FirstOrDefault(asset => asset.Name == "SHA256SUMS.txt");
            return new UpdateInfo
            {
                Version = versionText,
                Tag = tag,
                AssetName = chosen.Name,
                AssetUrl = chosen.Url,
                AssetSize = chosen.Size,
                SumsUrl = sums.Name is null ? null : sums.Url,
                Notes = notes,
                IsNewer = latest > Normalize(current),
            };
        }
        catch
        {
            return null;
        }
    }

    /// <summary>Downloads, verifies and schedules the replacement; the caller must exit afterwards.</summary>
    public static async Task<(bool Ok, string Message)> InstallAsync(
        UpdateInfo info,
        IProgress<(string Phase, double? Percent)>? progress = null)
    {
        var exe = CurrentExePath;
        if (string.IsNullOrEmpty(exe) || !File.Exists(exe)) return (false, "実行ファイルのパスを特定できませんでした。");
        var targetDir = Path.GetDirectoryName(exe);
        if (string.IsNullOrEmpty(targetDir)) return (false, "インストール先を特定できませんでした。");

        // Another launcher instance would keep the exe locked; ask the user to close it first.
        try
        {
            var self = Environment.ProcessId;
            foreach (var process in Process.GetProcessesByName(Path.GetFileNameWithoutExtension(exe)))
            {
                if (process.Id == self) continue;
                string? other = null;
                try { other = process.MainModule?.FileName; } catch { /* other user */ }
                if (string.Equals(other, exe, StringComparison.OrdinalIgnoreCase))
                {
                    return (false, "別の DSH Launcher が起動中です。終了してから更新してください。");
                }
            }
        }
        catch
        {
            // Best-effort check only.
        }

        try
        {
            var probe = Path.Combine(targetDir, $".dshl-write-test-{Guid.NewGuid():N}");
            File.WriteAllText(probe, "");
            File.Delete(probe);
        }
        catch
        {
            return (false, $"更新先に書き込めません（管理者権限が必要かもしれません）。\n{targetDir}");
        }

        var temp = Path.Combine(Path.GetTempPath(), $"dshl-update-{info.Version}-{Guid.NewGuid():N}.exe");
        try
        {
            progress?.Report(("ダウンロード中", 0));
            await DownloadAsync(info.AssetUrl, temp, percent => progress?.Report(("ダウンロード中", percent)));

            progress?.Report(("検証中", null));
            var expected = info.SumsUrl is null ? null : await FindChecksumAsync(info.SumsUrl, info.AssetName);
            if (expected is null) return (false, "SHA256SUMS.txt からチェックサムを取得できませんでした。");
            var actual = await ComputeSha256Async(temp);
            if (!actual.Equals(expected, StringComparison.OrdinalIgnoreCase))
            {
                return (false, "ダウンロードしたファイルのチェックサムが一致しませんでした。");
            }

            progress?.Report(("適用中", null));
            var helper = Path.Combine(Path.GetTempPath(), $"dshl-update-{Guid.NewGuid():N}.ps1");
            File.WriteAllText(helper, BuildHelperScript(temp, exe), new UTF8Encoding(true));
            StartHelper(helper);
            return (true, $"v{info.Version} を適用して再起動します。");
        }
        catch (Exception error)
        {
            return (false, error.Message);
        }
    }

    private static async Task DownloadAsync(string url, string path, Action<double?> onProgress)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
        using var response = await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);
        response.EnsureSuccessStatusCode();

        var total = response.Content.Headers.ContentLength;
        await using var source = await response.Content.ReadAsStreamAsync();
        await using var target = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None);
        var buffer = new byte[81920];
        long received = 0;
        while (true)
        {
            var read = await source.ReadAsync(buffer, 0, buffer.Length);
            if (read <= 0) break;
            await target.WriteAsync(buffer, 0, read);
            received += read;
            if (total is > 0) onProgress(received * 100.0 / total.Value);
        }
        onProgress(100);
    }

    private static async Task<string?> FindChecksumAsync(string sumsUrl, string assetName)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, sumsUrl);
        request.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
        using var response = await Http.SendAsync(request);
        if (!response.IsSuccessStatusCode) return null;
        var text = await response.Content.ReadAsStringAsync();
        foreach (var line in text.Split('\n'))
        {
            var trimmed = line.Trim();
            var space = trimmed.IndexOf(' ');
            if (space <= 0) continue;
            var hash = trimmed[..space].Trim();
            var name = trimmed[(space + 1)..].Trim().TrimStart('*');
            if (name.Equals(assetName, StringComparison.OrdinalIgnoreCase)) return hash;
        }
        return null;
    }

    private static async Task<string> ComputeSha256Async(string path)
    {
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        var hash = await SHA256.HashDataAsync(stream);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    private static void StartHelper(string helper)
    {
        var powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
        if (!File.Exists(powershell)) powershell = "powershell.exe";
        var psi = new ProcessStartInfo(powershell, $"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{helper}\"")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        Process.Start(psi);
    }

    /// <summary>
    /// Waits for this process to exit, replaces the exe, relaunches it, and deletes itself.
    /// Written as UTF-8 with BOM so Windows PowerShell 5.1 handles non-ASCII install paths.
    /// </summary>
    private static string BuildHelperScript(string source, string target)
    {
        const string template = """
$ErrorActionPreference = 'SilentlyContinue'
$source = '@SOURCE@'
$target = '@TARGET@'
for ($i = 0; $i -lt 120; $i++) {
    Start-Sleep -Milliseconds 500
    try {
        Move-Item -LiteralPath $source -Destination $target -Force -ErrorAction Stop
        Start-Sleep -Milliseconds 200
        Start-Process -FilePath $target -WorkingDirectory (Split-Path -LiteralPath $target)
        Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
        return
    } catch { }
}
""";
        return template
            .Replace("@SOURCE@", source.Replace("'", "''"))
            .Replace("@TARGET@", target.Replace("'", "''"));
    }

    private static bool IsSelfContained(string? exe)
    {
        try
        {
            return exe is not null && new FileInfo(exe).Length > 20L * 1024 * 1024;
        }
        catch
        {
            return false;
        }
    }

    private static Version Normalize(Version version) =>
        new(version.Major, version.Minor, Math.Max(version.Build, 0));

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromMinutes(30) };
        client.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", UserAgent);
        return client;
    }
}
