using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace DshLauncher;

/// <summary>Result of asking for a forward to one machine.</summary>
internal readonly record struct TunnelResult(bool Ok, int Port, string Message)
{
    public static TunnelResult Fail(string message) => new(false, 0, message);
}

/// <summary>
/// SSH port forwards that expose a remote DSH's loopback listener on this PC.
///
/// The remote DSH binds 127.0.0.1 only, so a browser here cannot reach it directly. A forward
/// gives this PC the same authority shape the remote DSH already trusts (loopback), without
/// changing any remote configuration. A forward lives until the launcher exits, so a URL issued
/// through it only works while the launcher is running.
/// </summary>
internal static class SshTunnels
{
    private const int FirstPort = 13080;
    private const int PortAttempts = 16;
    private static readonly SemaphoreSlim Gate = new(1, 1);
    private static readonly object Sync = new();
    private static readonly Dictionary<string, Tunnel> Active = new(StringComparer.Ordinal);

    static SshTunnels()
    {
        // A CLI that exits without Hold (issuance failed) must not leave ssh behind.
        AppDomain.CurrentDomain.ProcessExit += (_, _) => DisposeAll();
    }

    private sealed class Tunnel : IDisposable
    {
        public required string MachineId { get; init; }
        public required int Port { get; init; }
        public required Process Process { get; init; }

        public void Dispose()
        {
            try { if (!Process.HasExited) Process.Kill(entireProcessTree: true); } catch { }
            Process.Dispose();
        }
    }

    /// <summary>Returns a live forward for the machine, starting one when needed.</summary>
    public static async Task<TunnelResult> EnsureAsync(Machine machine)
    {
        await Gate.WaitAsync().ConfigureAwait(false);
        try
        {
            Tunnel? existing = null;
            lock (Sync) Active.TryGetValue(machine.Id, out existing);
            if (existing is not null)
            {
                if (!existing.Process.HasExited && await IsListeningAsync(existing.Port).ConfigureAwait(false))
                {
                    return new TunnelResult(true, existing.Port, "");
                }
                lock (Sync) Active.Remove(machine.Id);
                existing.Dispose();
            }

            var alias = machine.SshAlias ?? machine.Id;
            string? lastDetail = null;
            for (var port = FirstPort; port < FirstPort + PortAttempts; port++)
            {
                if (!IsFree(port)) continue;
                Process process;
                try
                {
                    process = Start(alias, port, machine.Port);
                }
                catch (Exception error)
                {
                    return TunnelResult.Fail($"SSH トンネルを開けませんでした。{error.Message}");
                }

                var errors = process.StandardError.ReadToEndAsync();
                _ = process.StandardOutput.ReadToEndAsync();
                var ready = false;
                var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(6);
                while (DateTime.UtcNow < deadline)
                {
                    if (process.HasExited) break;
                    if (await IsListeningAsync(port).ConfigureAwait(false)) { ready = true; break; }
                    await Task.Delay(120).ConfigureAwait(false);
                }

                if (ready)
                {
                    var tunnel = new Tunnel { MachineId = machine.Id, Port = port, Process = process };
                    lock (Sync) Active[machine.Id] = tunnel;
                    return new TunnelResult(true, port, "");
                }

                if (!process.HasExited)
                {
                    try { process.Kill(entireProcessTree: true); } catch { }
                }
                lastDetail = await FirstLineAsync(errors).ConfigureAwait(false);
                process.Dispose();

                // The port may have been taken between the check and ssh's bind: try the next one.
                if (lastDetail.Contains("Address already in use", StringComparison.OrdinalIgnoreCase) ||
                    lastDetail.Contains("cannot listen to port", StringComparison.OrdinalIgnoreCase) ||
                    lastDetail.Contains("Could not request local forwarding", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }
                return TunnelResult.Fail($"SSH トンネルを開けませんでした。{lastDetail}");
            }
            return TunnelResult.Fail(lastDetail is null
                ? "SSH トンネルに使える空きポートが見つかりませんでした。"
                : $"SSH トンネルを開けませんでした。{lastDetail}");
        }
        finally
        {
            Gate.Release();
        }
    }

    public static bool IsAlive(string machineId)
    {
        lock (Sync)
        {
            return Active.TryGetValue(machineId, out var tunnel) && !tunnel.Process.HasExited;
        }
    }

    public static void Dispose(string machineId)
    {
        Tunnel? tunnel = null;
        lock (Sync) { if (Active.Remove(machineId, out var found)) tunnel = found; }
        tunnel?.Dispose();
    }

    public static void DisposeAll()
    {
        List<Tunnel> tunnels;
        lock (Sync)
        {
            tunnels = Active.Values.ToList();
            Active.Clear();
        }
        foreach (var tunnel in tunnels) tunnel.Dispose();
    }

    private static Process Start(string alias, int localPort, int remotePort)
    {
        var psi = new ProcessStartInfo("ssh")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var arg in new[]
                 {
                     "-N",
                     "-o", "BatchMode=yes",
                     "-o", "ConnectTimeout=5",
                     "-o", "StrictHostKeyChecking=accept-new",
                     "-o", "ExitOnForwardFailure=yes",
                     "-o", "ServerAliveInterval=15",
                     "-o", "ServerAliveCountMax=3",
                     "-L", $"127.0.0.1:{localPort}:127.0.0.1:{remotePort}",
                     alias,
                 })
        {
            psi.ArgumentList.Add(arg);
        }
        var process = new Process { StartInfo = psi };
        if (!process.Start()) throw new InvalidOperationException("failed to start ssh");
        return process;
    }

    private static bool IsFree(int port)
    {
        try
        {
            using var listener = new TcpListener(IPAddress.Loopback, port);
            listener.Start();
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static async Task<bool> IsListeningAsync(int port,
        int timeoutMs = 300)
    {
        try
        {
            using var client = new TcpClient();
            using var timeout = new CancellationTokenSource(timeoutMs);
            await client.ConnectAsync(IPAddress.Loopback, port, timeout.Token).ConfigureAwait(false);
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static async Task<string> FirstLineAsync(Task<string> text)
    {
        var done = await Task.WhenAny(text, Task.Delay(1000)).ConfigureAwait(false);
        var value = done == text ? await text.ConfigureAwait(false) : "";
        var line = value.Split('\n')
            .Select(candidate => candidate.Trim())
            .FirstOrDefault(candidate => candidate.Length > 0);
        return line ?? "ssh が終了しました。";
    }
}
