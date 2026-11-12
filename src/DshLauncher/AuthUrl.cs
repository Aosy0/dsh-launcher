using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace DshLauncher;

/// <summary>One issued browser-authentication URL, with the addresses it can be opened from.</summary>
internal sealed class AuthUrlInfo
{
    public bool Ok { get; init; }
    public string Message { get; init; } = "";
    public string? Url { get; init; }
    public string? LocalUrl { get; init; }
    public string? ExternalUrl { get; init; }
    public string? Token { get; init; }
    public int? Pid { get; init; }

    public static AuthUrlInfo Fail(string message) => new() { Ok = false, Message = message };
}

/// <summary>
/// Issues the `?token=` URL that authenticates a *new* browser against the local DSH.
///
/// dsh web mints a random launch token per process and prints it once at startup as
/// <c>dsh web: &lt;url&gt;?token=...</c>. The token is never persisted, so the startup line in the
/// launcher's log is the only source. The log is written through a shell append redirect (`&gt;&gt;`)
/// and is opened here with <see cref="FileShare.ReadWrite"/>, so it stays readable while dsh runs.
///
/// Log entries from earlier runs remain in the file, so a candidate is accepted only after the
/// running server answers its token with a redirect that mints the `dsh-auth-` cookie: a stale
/// token gets 401, and a cookie-bearing client would get a redirect without a fresh cookie. The
/// token itself does not depend on the authority, so the same value can be offered on the loopback
/// URL (this PC) and on the configured public URL (another device).
/// </summary>
internal static class AuthUrls
{
    private const int MaxLogBytes = 256 * 1024;
    private const int MaxCandidates = 6;
    private static readonly TimeSpan StartupGrace = TimeSpan.FromSeconds(2.5);

    private static readonly Regex UrlLine = new(@"dsh web:\s*(?<url>https?://\S+)", RegexOptions.Compiled);
    private static readonly HttpClient Http = CreateClient();

    /// <summary>Issues the URL for a running local DSH, or explains why it cannot.</summary>
    public static async Task<AuthUrlInfo> IssueAsync(Machine machine)
    {
        if (machine.Kind != MachineKind.Local)
        {
            return AuthUrlInfo.Fail("認証 URL はこの PC の DSH で発行できます（リモートは未対応です）。");
        }

        var pid = Ports.ListenerPid(machine.Port);
        if (pid is null)
        {
            return AuthUrlInfo.Fail("DSH が停止しています。起動してから発行してください。");
        }

        // dsh prints the URL a moment after the port opens: retry briefly before giving up.
        var deadline = DateTime.UtcNow + StartupGrace;
        var sawStartupLine = false;
        while (true)
        {
            foreach (var candidate in Candidates(machine))
            {
                sawStartupLine = true;
                if (DateTime.UtcNow >= deadline) break;
                var token = TokenOf(candidate);
                if (token is null) continue;
                if (!await IsLiveAsync(machine, token)) continue;
                return Build(machine, candidate, token, pid.Value);
            }

            if (DateTime.UtcNow >= deadline) break;
            await Task.Delay(300);
        }

        return AuthUrlInfo.Fail(sawStartupLine
            ? "起動時の認証 URL は古くなっています。ランチャーから再起動すると新しい URL を発行できます。"
            : "認証 URL を取得できませんでした。起動ログに `dsh web: …?token=…` がないためです（ランチャー経由で起動すると取得できます）。");
    }

    // ---------------------------------------------------------------- candidates

    /// <summary>Startup URLs in the log, newest first.</summary>
    private static IEnumerable<Uri> Candidates(Machine machine)
    {
        string[] lines;
        try
        {
            lines = ReadLogLines(Local.LogPath(machine));
        }
        catch
        {
            return Array.Empty<Uri>();
        }

        var urls = new List<Uri>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        for (var i = lines.Length - 1; i >= 0 && urls.Count < MaxCandidates; i--)
        {
            var match = UrlLine.Match(lines[i]);
            if (!match.Success) continue;
            if (!Uri.TryCreate(match.Groups["url"].Value.Trim(), UriKind.Absolute, out var uri)) continue;
            if (!seen.Add(uri.AbsoluteUri)) continue;
            urls.Add(uri);
        }
        return urls;
    }

    private static string[] ReadLogLines(string path)
    {
        if (!File.Exists(path)) return Array.Empty<string>();

        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        var start = Math.Max(0, stream.Length - MaxLogBytes);
        if (start > 0) stream.Seek(start, SeekOrigin.Begin);
        using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
        var lines = reader.ReadToEnd().Split('\n');
        // The first line of a windowed read starts mid-line; drop it.
        return start > 0 && lines.Length > 1 ? lines.Skip(1).ToArray() : lines;
    }

    private static string? TokenOf(Uri url)
    {
        var query = url.Query;
        if (query.Length < 2) return null;
        foreach (var pair in query[1..].Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var at = pair.IndexOf('=');
            if (at <= 0) continue;
            if (!pair[..at].Equals("token", StringComparison.Ordinal)) continue;
            var value = Uri.UnescapeDataString(pair[(at + 1)..]);
            return value.Length == 0 ? null : value;
        }
        return null;
    }

    /// <summary>
    /// True when the running server accepts this token. A valid token mints the browser-session
    /// cookie (`Set-Cookie: dsh-auth-…`) on its redirect, so the probe requires both: a redirect
    /// alone can also mean the client already holds a cookie (a stale token is then accepted) or
    /// that another service answers on the port.
    /// </summary>
    private static async Task<bool> IsLiveAsync(Machine machine, string token)
    {
        foreach (var host in new[] { "127.0.0.1", "localhost" })
        {
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, WithToken($"http://{host}:{machine.Port}/", token));
                using var response = await Http.SendAsync(request);
                // 401 is the server's definitive answer for a token from an earlier run.
                if ((int)response.StatusCode == 401) return false;
                if ((int)response.StatusCode is >= 300 and < 400 && MintsSession(response)) return true;
            }
            catch
            {
                // Try the other loopback spelling before calling the candidate dead.
            }
        }
        return false;
    }

    private static bool MintsSession(HttpResponseMessage response)
    {
        if (!response.Headers.TryGetValues("Set-Cookie", out var cookies)) return false;
        return cookies.Any(cookie => cookie.StartsWith("dsh-auth-", StringComparison.OrdinalIgnoreCase));
    }

    private static AuthUrlInfo Build(Machine machine, Uri printed, string token, int pid)
    {
        var localUrl = WithToken($"http://127.0.0.1:{machine.Port}/", token);

        Uri? external = null;
        if (!string.IsNullOrWhiteSpace(machine.Url) &&
            Uri.TryCreate(machine.Url.Trim(), UriKind.Absolute, out var configured) &&
            IsWeb(configured))
        {
            external = configured;
        }
        if (external is null && IsWeb(printed) && !IsLoopback(printed)) external = printed;

        var externalUrl = external is null ? null : WithToken(external.AbsoluteUri, token);
        return new AuthUrlInfo
        {
            Ok = true,
            Url = externalUrl ?? localUrl,
            LocalUrl = localUrl,
            ExternalUrl = externalUrl,
            Token = token,
            Pid = pid,
        };
    }

    // ---------------------------------------------------------------- helpers

    /// <summary>Replaces the token parameter while keeping the rest of the address.</summary>
    private static string WithToken(string baseUrl, string token)
    {
        var uri = new Uri(baseUrl, UriKind.Absolute);
        var builder = new UriBuilder(WithoutToken(uri));
        var pairs = builder.Query.TrimStart('?')
            .Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Where(pair => !pair.Split('=', 2)[0].Equals("token", StringComparison.Ordinal))
            .ToList();
        pairs.Add("token=" + Uri.EscapeDataString(token));
        builder.Query = string.Join("&", pairs);
        return builder.Uri.AbsoluteUri;
    }

    private static Uri WithoutToken(Uri uri)
    {
        var builder = new UriBuilder(uri);
        var pairs = builder.Query.TrimStart('?')
            .Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Where(pair => !pair.Split('=', 2)[0].Equals("token", StringComparison.Ordinal))
            .ToList();
        builder.Query = string.Join("&", pairs);
        return builder.Uri;
    }

    private static bool IsWeb(Uri uri) =>
        (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps) && uri.Host.Length > 0;

    private static bool IsLoopback(Uri uri) =>
        uri.IsLoopback || uri.Host.Equals("localhost", StringComparison.OrdinalIgnoreCase);

    private static HttpClient CreateClient()
    {
        // The probe must reach the local listener directly: a system proxy would not.
        // Cookies stay out of the handler on purpose: a stored session cookie would make a stale
        // token look valid, because the server also redirects a request that already has one.
        var handler = new HttpClientHandler { AllowAutoRedirect = false, UseProxy = false, UseCookies = false };
        return new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(4) };
    }
}
