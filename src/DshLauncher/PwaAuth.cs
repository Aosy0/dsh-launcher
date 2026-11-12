using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace DshLauncher;

internal sealed class PwaAuthResult
{
    public bool Ok { get; init; }
    public string Message { get; init; } = "";
    public bool Authenticated { get; init; }
    public bool AuthUrlIssued { get; init; }
}

/// <summary>
/// Browser authentication for the PWA ("PWA を開く").
///
/// dsh web protects the UI with a signed HttpOnly cookie (`dsh-auth-&lt;hash of authority&gt;`) that is
/// normally minted by opening the process-token URL printed at startup. The launcher cannot read
/// that URL back while dsh is running (the redirected stdout file is exclusively locked), so it mints
/// the same cookie from the persistent browser-session secret in `$DSH_HOME/.credentials.yaml`,
/// installs it into the target browser profile through a short-lived local page inside a hidden app
/// window, and remembers the auth state. Auth state is also checked live from the PWA window title:
/// a 401 page is titled with the authority (e.g. "127.0.0.1:3080") while the authenticated UI carries
/// the app name.
/// </summary>
internal static class PwaAuth
{
    private const uint WM_CLOSE = 0x0010;
    private const int SW_HIDE = 0;
    private const string CookiePrefix = "dsh-auth-";
    private const string FallbackAppName = "DeepSeek Harness";

    private static readonly TimeSpan ObserveTimeout = TimeSpan.FromSeconds(6);
    private static readonly TimeSpan ShortObserveTimeout = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan AuthWindowTimeout = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan AuthTitleTimeout = TimeSpan.FromSeconds(10);

    private static readonly string StateDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "DshLauncher");
    private static readonly string StatePath = Path.Combine(StateDir, "pwa-auth.json");
    private static readonly object StateGate = new();

    private enum WindowStatus { Unknown, Authenticated, Unauthenticated }

    private sealed class CookieMaterial
    {
        public string Name { get; init; } = "";
        public string Value { get; init; } = "";
        public string OriginRoot { get; init; } = "";
        public string Authority { get; init; } = "";
        public DateTime ExpiresAtUtc { get; init; }
        public int MaxAgeSeconds { get; init; }
    }

    // ---------------------------------------------------------------- public API

    /// <summary>Remembers whether this browser profile was authenticated through the launcher.</summary>
    public static bool? KnownAuthenticated(BrowserAppInfo app)
    {
        var authority = AuthorityOf(app);
        if (authority is null) return null;

        lock (StateGate)
        {
            var entry = LoadState().Entries.FirstOrDefault(candidate => Matches(candidate, app, authority));
            if (entry is null) return null;
            return entry.ExpiresAtUtc > DateTime.UtcNow;
        }
    }

    /// <summary>True when the launcher can mint a browser session for this PWA (loopback origin + secret).</summary>
    public static bool CanAuthenticate(Machine local, BrowserAppInfo app)
    {
        var origin = OriginOf(app);
        if (origin is null || !IsLoopbackOrigin(origin)) return false;
        return ReadSecret(DshHome(local)) is not null;
    }

    /// <summary>Opens the PWA, minting a browser session first when the profile is not authenticated yet.</summary>
    public static async Task<PwaAuthResult> OpenAsync(Machine local, BrowserAppInfo app, Action<string>? log = null)
    {
        var authority = AuthorityOf(app);
        if (authority is null) return Fail("ブラウザの認証先を特定できませんでした。");

        var known = KnownAuthenticated(app);
        var launched = BrowserApps.Launch(app);
        if (!launched.Ok) return Fail(launched.Message);

        var status = await ObserveAsync(app, authority, known == true ? ShortObserveTimeout : ObserveTimeout);
        if (status == WindowStatus.Authenticated)
        {
            if (known != true) Remember(app, authority, DateTime.UtcNow.AddDays(30));
            return new PwaAuthResult { Ok = true, Authenticated = true, Message = "opened " + app.Label };
        }
        if (status == WindowStatus.Unknown)
        {
            // The window did not surface in time: do not interfere with whatever the browser is doing.
            return new PwaAuthResult { Ok = true, Message = "opened " + app.Label };
        }

        // A 401 window is open: mint the browser session and reload the PWA.
        var material = await PrepareCookieAsync(local, app);
        if (material is null)
        {
            return Fail("認証情報を取得できませんでした。DSH の .credentials.yaml（ブラウザセッション）を確認するか、dsh web を起動し直してください。");
        }

        log?.Invoke("ブラウザの認証を更新");
        await InstallCookieAsync(app, material);
        CloseWindowsWithTitle(app, authority);
        await Task.Delay(250);

        var relaunched = BrowserApps.Launch(app);
        if (!relaunched.Ok) return Fail(relaunched.Message);

        var after = await ObserveAsync(app, authority, ObserveTimeout);
        if (after == WindowStatus.Unauthenticated)
        {
            return Fail("認証を更新しましたが、PWA が認証状態になりませんでした。ブラウザで DSH を開き直してください。");
        }

        Remember(app, authority, material.ExpiresAtUtc);
        return new PwaAuthResult { Ok = true, Authenticated = true, AuthUrlIssued = true, Message = "opened " + app.Label };
    }

    // ---------------------------------------------------------------- cookie material

    /// <summary>
    /// Builds the exact cookie dsh web would mint for this authority and verifies it against the
    /// running server before touching the browser.
    /// </summary>
    private static async Task<CookieMaterial?> PrepareCookieAsync(Machine local, BrowserAppInfo app)
    {
        var origin = OriginOf(app);
        if (origin is null || !IsLoopbackOrigin(origin)) return null;

        var secret = ReadSecret(DshHome(local));
        if (secret is null) return null;

        var authority = AuthorityFor(origin);
        var days = MaxAgeDays(DshHome(local), local);
        var lifetime = TimeSpan.FromDays(Math.Min(days * 0.95, 400));
        var issuedAt = DateTimeOffset.UtcNow;
        var expiresAt = issuedAt + lifetime;

        var name = CookiePrefix + Base64Url(SHA256.HashData(Encoding.UTF8.GetBytes(authority)));
        var payload = "{\"version\":1,\"authority\":\"" + JsonEscape(authority) +
                      "\",\"issuedAt\":" + issuedAt.ToUnixTimeMilliseconds() +
                      ",\"expiresAt\":" + expiresAt.ToUnixTimeMilliseconds() + "}";
        // dsh web signs the base64url body itself: <version>.<body>.<hmac(secret, body)>
        var body = Base64Url(Encoding.UTF8.GetBytes(payload));
        using var hmac = new HMACSHA256(secret);
        var signature = Base64Url(hmac.ComputeHash(Encoding.ASCII.GetBytes(body)));
        var value = "v1." + body + "." + signature;

        var originRoot = $"{origin.Scheme}://{origin.Authority}/";
        try
        {
            using var handler = new HttpClientHandler { AllowAutoRedirect = false };
            using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(5) };
            using var request = new HttpRequestMessage(HttpMethod.Get, originRoot);
            request.Headers.TryAddWithoutValidation("Cookie", name + "=" + value);
            using var response = await client.SendAsync(request);
            if ((int)response.StatusCode != 200) return null;
        }
        catch
        {
            return null;
        }

        return new CookieMaterial
        {
            Name = name,
            Value = value,
            OriginRoot = originRoot,
            Authority = authority,
            ExpiresAtUtc = expiresAt.UtcDateTime,
            MaxAgeSeconds = (int)Math.Max(60, lifetime.TotalSeconds),
        };
    }

    /// <summary>
    /// Serves a one-shot page that sets the cookie for the loopback host (cookies ignore ports) and
    /// redirects to DSH. The page is opened in a hidden app window of the target profile and the
    /// window is closed as soon as the browser follows it.
    /// </summary>
    private static async Task InstallCookieAsync(BrowserAppInfo app, CookieMaterial material)
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port;
        try
        {
            port = ((IPEndPoint)listener.LocalEndpoint).Port;
        }
        catch
        {
            listener.Stop();
            return;
        }

        var served = 0;
        var stopping = false;
        var server = Task.Run(async () =>
        {
            while (!stopping)
            {
                TcpClient client;
                try
                {
                    client = await listener.AcceptTcpClientAsync();
                }
                catch
                {
                    break;
                }

                _ = Task.Run(async () =>
                {
                    try
                    {
                        using (client)
                        {
                            var stream = client.GetStream();
                            var buffer = new byte[4096];
#pragma warning disable CA2022 // only the request arrival matters; the bytes are not parsed
                            try { await stream.ReadAsync(buffer, 0, buffer.Length); } catch { /* request line is irrelevant */ }
#pragma warning restore CA2022

                            var response =
                                "HTTP/1.1 302 Found\r\n" +
                                $"Set-Cookie: {material.Name}={material.Value}; Max-Age={material.MaxAgeSeconds}; Path=/; HttpOnly; SameSite=Strict\r\n" +
                                $"Location: {material.OriginRoot}\r\n" +
                                "Cache-Control: no-store\r\n" +
                                "Connection: close\r\n" +
                                "Content-Length: 0\r\n\r\n";
                            var bytes = Encoding.ASCII.GetBytes(response);
                            await stream.WriteAsync(bytes, 0, bytes.Length);
                            await stream.FlushAsync();
                            Interlocked.Increment(ref served);
                        }
                    }
                    catch
                    {
                        // The browser may abort the connection after the redirect.
                    }
                });
            }
        });

        try
        {
            var browserExe = app.BrowserExe;
            if (string.IsNullOrWhiteSpace(browserExe) || !File.Exists(browserExe)) return;

            var before = VisibleWindows()
                .Where(window => IsBrowserProcess(window.Pid, app))
                .Select(window => window.Hwnd)
                .ToHashSet();

            var pageUrl = $"http://127.0.0.1:{port}/";
            try
            {
                var psi = new ProcessStartInfo(browserExe, $"--profile-directory=\"{app.ProfileDirectory}\" --app=\"{pageUrl}\"")
                {
                    UseShellExecute = true,
                    WorkingDirectory = Path.GetDirectoryName(browserExe) ?? "",
                };
                Process.Start(psi);
            }
            catch
            {
                return;
            }

            var authWindow = IntPtr.Zero;
            var windowDeadline = DateTime.UtcNow + AuthWindowTimeout;
            while (DateTime.UtcNow < windowDeadline)
            {
                if (Volatile.Read(ref served) > 0) break;
                var candidate = VisibleWindows()
                    .Where(window => IsBrowserProcess(window.Pid, app) && !before.Contains(window.Hwnd))
                    .OrderBy(window => window.Hwnd)
                    .Select(window => window.Hwnd)
                    .FirstOrDefault();
                if (candidate != IntPtr.Zero)
                {
                    authWindow = candidate;
                    HideWindow(authWindow);
                }
                await Task.Delay(60);
            }

            // Give the browser a moment to commit the cookie and follow the redirect to DSH.
            var titleDeadline = DateTime.UtcNow + AuthTitleTimeout;
            while (DateTime.UtcNow < titleDeadline)
            {
                if (authWindow == IntPtr.Zero) break;
                var title = WindowTitle(authWindow);
                if (IsAuthenticatedTitle(title, app)) break;
                if (Volatile.Read(ref served) > 0 && title.Length == 0) break;
                await Task.Delay(80);
            }

            await Task.Delay(400);
            if (authWindow != IntPtr.Zero) CloseWindow(authWindow);
        }
        finally
        {
            stopping = true;
            try { listener.Stop(); } catch { /* already stopped */ }
            try { await server; } catch { /* best-effort */ }
        }
    }

    private static string DshHome(Machine local)
    {
        if (local.Environment.TryGetValue("DSH_HOME", out var configured) && !string.IsNullOrWhiteSpace(configured))
        {
            return Environment.ExpandEnvironmentVariables(configured);
        }
        var fromEnvironment = Environment.GetEnvironmentVariable("DSH_HOME");
        if (!string.IsNullOrWhiteSpace(fromEnvironment)) return fromEnvironment;
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".dsh");
    }

    private static byte[]? ReadSecret(string dshHome)
    {
        try
        {
            var path = Path.Combine(dshHome, ".credentials.yaml");
            if (!File.Exists(path)) return null;

            var inRecord = false;
            var recordIndent = -1;
            foreach (var line in File.ReadAllLines(path))
            {
                var trimmed = line.Trim();
                if (trimmed.Length == 0 || trimmed.StartsWith("#", StringComparison.Ordinal)) continue;
                var indent = line.Length - line.TrimStart().Length;

                if (!inRecord && trimmed.StartsWith("client-connection/browser-session:", StringComparison.Ordinal))
                {
                    inRecord = true;
                    recordIndent = indent;
                    continue;
                }
                if (!inRecord) continue;
                if (indent <= recordIndent)
                {
                    inRecord = false;
                    continue;
                }
                if (!trimmed.StartsWith("secret:", StringComparison.Ordinal)) continue;
                var value = trimmed["secret:".Length..].Trim().Trim('"', '\'');
                var secret = DecodeBase64Url(value);
                return secret is { Length: 32 } ? secret : null;
            }
        }
        catch
        {
            // A missing or unreadable credentials file disables automatic authentication.
        }
        return null;
    }

    private static double MaxAgeDays(string dshHome, Machine local)
    {
        var days = 30.0;
        var candidates = new[]
        {
            Path.Combine(dshHome, "cordis.patch.yml"),
            Path.Combine(dshHome, "profiles", local.Profile, "cordis.patch.yml"),
        };
        foreach (var path in candidates)
        {
            try
            {
                if (!File.Exists(path)) continue;
                var text = File.ReadAllText(path);
                foreach (Match match in Regex.Matches(text, @"cookieMaxAgeDays\s*:\s*(\d+)"))
                {
                    if (double.TryParse(match.Groups[1].Value, out var value) && value >= 1) days = value;
                }
            }
            catch
            {
                // Fall back to the shipped default.
            }
        }
        return days;
    }

    // ---------------------------------------------------------------- state

    private static void Remember(BrowserAppInfo app, string authority, DateTime expiresAtUtc)
    {
        lock (StateGate)
        {
            var file = LoadState();
            var existing = file.Entries.FirstOrDefault(candidate => Matches(candidate, app, authority));
            if (existing is null)
            {
                file.Entries.Add(new PwaAuthEntry
                {
                    Browser = app.Browser,
                    Profile = app.ProfileDirectory,
                    Authority = authority,
                    ExpiresAtUtc = expiresAtUtc,
                });
            }
            else
            {
                existing.ExpiresAtUtc = expiresAtUtc;
            }
            file.Entries.RemoveAll(entry => entry.ExpiresAtUtc <= DateTime.UtcNow.AddDays(-1));
            SaveState(file);
        }
    }

    private static bool Matches(PwaAuthEntry entry, BrowserAppInfo app, string authority) =>
        entry.Authority.Equals(authority, StringComparison.OrdinalIgnoreCase) &&
        entry.Profile.Equals(app.ProfileDirectory, StringComparison.OrdinalIgnoreCase) &&
        entry.Browser.Equals(app.Browser, StringComparison.OrdinalIgnoreCase);

    private static PwaAuthFile LoadState()
    {
        try
        {
            if (File.Exists(StatePath))
            {
                var loaded = JsonSerializer.Deserialize<PwaAuthFile>(File.ReadAllText(StatePath), Json.Options);
                if (loaded is { Version: 1 }) return loaded;
            }
        }
        catch
        {
            // A broken state file only means the launcher re-checks authentication once.
        }
        return new PwaAuthFile();
    }

    private static void SaveState(PwaAuthFile file)
    {
        try
        {
            Directory.CreateDirectory(StateDir);
            File.WriteAllText(StatePath, JsonSerializer.Serialize(file, Json.Options));
        }
        catch
        {
            // Persisting the hint is best-effort.
        }
    }

    // ---------------------------------------------------------------- windows

    private static async Task<WindowStatus> ObserveAsync(BrowserAppInfo app, string authority, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            var status = EvaluateWindows(app, authority);
            if (status != WindowStatus.Unknown) return status;
            await Task.Delay(120);
        }
        return WindowStatus.Unknown;
    }

    private static WindowStatus EvaluateWindows(BrowserAppInfo app, string authority)
    {
        var sawUnauthenticated = false;
        foreach (var window in VisibleWindows())
        {
            if (!IsBrowserProcess(window.Pid, app)) continue;
            if (IsAuthenticatedTitle(window.Title, app)) return WindowStatus.Authenticated;
            if (IsUnauthenticatedTitle(window.Title, authority)) sawUnauthenticated = true;
        }
        return sawUnauthenticated ? WindowStatus.Unauthenticated : WindowStatus.Unknown;
    }

    private static void CloseWindowsWithTitle(BrowserAppInfo app, string authority)
    {
        foreach (var window in VisibleWindows())
        {
            if (!IsBrowserProcess(window.Pid, app)) continue;
            if (!IsUnauthenticatedTitle(window.Title, authority)) continue;
            CloseWindow(window.Hwnd);
        }
    }

    private static bool IsAuthenticatedTitle(string title, BrowserAppInfo app)
    {
        if (string.IsNullOrWhiteSpace(title)) return false;
        var name = string.IsNullOrWhiteSpace(app.Label) ? FallbackAppName : app.Label;
        return title.Contains(name, StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsUnauthenticatedTitle(string title, string authority)
    {
        if (string.IsNullOrWhiteSpace(title)) return false;
        var trimmed = title.Trim().TrimEnd('/');
        return trimmed.Equals(authority, StringComparison.OrdinalIgnoreCase);
    }

    private static IEnumerable<(IntPtr Hwnd, uint Pid, string Title)> VisibleWindows()
    {
        var windows = new List<(IntPtr, uint, string)>();
        try
        {
            EnumWindows((handle, _) =>
            {
                if (!IsWindowVisible(handle)) return true;
                GetWindowThreadProcessId(handle, out var pid);
                var title = WindowTitle(handle);
                if (!string.IsNullOrEmpty(title)) windows.Add((handle, pid, title));
                return true;
            }, IntPtr.Zero);
        }
        catch
        {
            // Window enumeration is best-effort.
        }
        return windows;
    }

    private static readonly Dictionary<uint, string> ProcessNames = new();

    private static bool IsBrowserProcess(uint pid, BrowserAppInfo app)
    {
        string? name;
        lock (ProcessNames)
        {
            if (!ProcessNames.TryGetValue(pid, out name))
            {
                try { name = Process.GetProcessById((int)pid).ProcessName; }
                catch { name = ""; }
                ProcessNames[pid] = name;
            }
        }

        var expected = Path.GetFileNameWithoutExtension(app.BrowserExe);
        if (!string.IsNullOrWhiteSpace(expected)) return name!.Equals(expected, StringComparison.OrdinalIgnoreCase);

        return name is "chrome" or "msedge" or "brave" or "vivaldi" or "chromium";
    }

    private static string WindowTitle(IntPtr handle)
    {
        try
        {
            var buffer = new StringBuilder(512);
            var length = GetWindowText(handle, buffer, buffer.Capacity);
            return length > 0 ? buffer.ToString() : "";
        }
        catch
        {
            return "";
        }
    }

    private static void HideWindow(IntPtr handle)
    {
        try { ShowWindow(handle, SW_HIDE); } catch { /* cosmetic */ }
    }

    private static void CloseWindow(IntPtr handle)
    {
        try { PostMessage(handle, WM_CLOSE, IntPtr.Zero, IntPtr.Zero); } catch { /* best-effort */ }
    }

    // ---------------------------------------------------------------- helpers

    private static Uri? OriginOf(BrowserAppInfo app)
    {
        var manifestId = app.ManifestId;
        if (!string.IsNullOrWhiteSpace(manifestId) && Uri.TryCreate(manifestId, UriKind.Absolute, out var uri)) return uri;
        return null;
    }

    private static string? AuthorityOf(BrowserAppInfo app)
    {
        var origin = OriginOf(app);
        return origin is null ? null : AuthorityFor(origin);
    }

    /// <summary>Authority spelling dsh web uses for its cookie payload (http: host:port, https: origin).</summary>
    private static string AuthorityFor(Uri origin) =>
        origin.Scheme == Uri.UriSchemeHttps ? $"{origin.Scheme}://{origin.Authority}" : origin.Authority;

    private static bool IsLoopbackOrigin(Uri origin) =>
        origin.IsLoopback || origin.Host.Equals("localhost", StringComparison.OrdinalIgnoreCase);

    private static string Base64Url(byte[] bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static byte[]? DecodeBase64Url(string value)
    {
        try
        {
            var normalized = value.Replace('-', '+').Replace('_', '/');
            switch (normalized.Length % 4)
            {
                case 2: normalized += "=="; break;
                case 3: normalized += "="; break;
                case 1: return null;
            }
            return Convert.FromBase64String(normalized);
        }
        catch
        {
            return null;
        }
    }

    private static string JsonEscape(string value)
    {
        var builder = new StringBuilder(value.Length);
        foreach (var character in value)
        {
            switch (character)
            {
                case '"': builder.Append("\\\""); break;
                case '\\': builder.Append("\\\\"); break;
                case '\n': builder.Append("\\n"); break;
                case '\r': builder.Append("\\r"); break;
                case '\t': builder.Append("\\t"); break;
                default:
                    if (character < 0x20) builder.Append("\\u").Append(((int)character).ToString("x4"));
                    else builder.Append(character);
                    break;
            }
        }
        return builder.ToString();
    }

    private static PwaAuthResult Fail(string message) => new() { Ok = false, Message = message };

    private sealed class PwaAuthFile
    {
        public int Version { get; set; } = 1;
        public List<PwaAuthEntry> Entries { get; set; } = new();
    }

    private sealed class PwaAuthEntry
    {
        public string Browser { get; set; } = "";
        public string Profile { get; set; } = "";
        public string Authority { get; set; } = "";
        public DateTime ExpiresAtUtc { get; set; }
    }

    // ---------------------------------------------------------------- Win32

    private delegate bool EnumWindowsProc(IntPtr handle, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr handle);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr handle, StringBuilder text, int count);

    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr handle, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr handle, int command);
}
