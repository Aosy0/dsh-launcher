using System.IO;
using System.Threading;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Diagnostics;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace DshLauncher;

internal enum MachineKind { Local, Ssh }

internal enum MachineState { Unknown, Running, Starting, Stopped, NeedsSetup, Unreachable }

internal sealed class Machine
{
    public string Id { get; set; } = "";
    public MachineKind Kind { get; set; }
    public string Name { get; set; } = "";
    public string? SshAlias { get; set; }
    public string Platform { get; set; } = "auto";
    public string Profile { get; set; } = "web";
    public int Port { get; set; } = 3080;
    public string? Url { get; set; }
    public bool Pinned { get; set; } = true;
    public Dictionary<string, string> Environment { get; set; } = new();

    [JsonIgnore]
    public string DisplayName => Kind == MachineKind.Local ? $"{Name}(local)" : Name;

    [JsonIgnore]
    public string TargetUrl => string.IsNullOrWhiteSpace(Url) ? $"http://127.0.0.1:{Port}/" : Url!;
}

internal sealed class LauncherConfig
{
    public int Version { get; set; } = 1;
    public List<Machine> Machines { get; set; } = new();

    public static string DefaultPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "DshLauncher", "hosts.json");

    public static LauncherConfig Load(string? path = null)
    {
        var file = path ?? DefaultPath;
        try
        {
            if (File.Exists(file))
            {
                var loaded = JsonSerializer.Deserialize<LauncherConfig>(File.ReadAllText(file), Json.Options);
                if (loaded is { Machines.Count: > 0 }) return loaded;
            }
        }
        catch
        {
            // A broken config falls back to defaults; the UI can save over it.
        }
        var created = CreateDefault();
        try { created.Save(path); } catch { }
        return created;
    }

    public void Save(string? path = null)
    {
        var file = path ?? DefaultPath;
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, JsonSerializer.Serialize(this, Json.Options));
    }

    public static LauncherConfig CreateDefault()
    {
        var config = new LauncherConfig();
        var host = Environment.MachineName.ToLowerInvariant();
        config.Machines.Add(new Machine
        {
            Id = "local",
            Kind = MachineKind.Local,
            Name = host,
            Profile = "web",
            Port = 3080,
        });

        foreach (var alias in Ssh.Aliases())
        {
            config.Machines.Add(new Machine
            {
                Id = alias,
                Kind = MachineKind.Ssh,
                Name = alias,
                SshAlias = alias,
                Platform = "auto",
                Profile = "web",
                Port = 3080,
            });
        }
        return config;
    }

    public Machine? Find(string idOrName)
    {
        foreach (var machine in Machines)
        {
            if (machine.Id.Equals(idOrName, StringComparison.OrdinalIgnoreCase)) return machine;
            if (machine.Name.Equals(idOrName, StringComparison.OrdinalIgnoreCase)) return machine;
            if (machine.DisplayName.Equals(idOrName, StringComparison.OrdinalIgnoreCase)) return machine;
        }
        return null;
    }

    public Machine LocalMachine =>
        Machines.FirstOrDefault(m => m.Kind == MachineKind.Local) ?? Machines.First();
}

internal static class Json
{
    public static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter() },
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };
}

internal sealed class MachineStatus
{
    public MachineState State { get; set; } = MachineState.Unknown;
    public int? Pid { get; set; }
    public int? Port { get; set; }
    public TimeSpan? Uptime { get; set; }
    public long? MemoryMb { get; set; }
    public string? Url { get; set; }
    public string? Platform { get; set; }
    public string? NodeVersion { get; set; }
    public bool? DshInstalled { get; set; }
    public bool? DshHome { get; set; }
    public bool? PortOpen { get; set; }
    public string? Note { get; set; }
    public string? Error { get; set; }
    public long? LatencyMs { get; set; }
    public string? Command { get; set; }

    [JsonIgnore] public bool IsRunning => State == MachineState.Running;
    [JsonIgnore] public string StateText => State switch
    {
        MachineState.Running => "稼働中",
        MachineState.Starting => "起動中",
        MachineState.Stopped => "停止",
        MachineState.NeedsSetup => "要セットアップ",
        MachineState.Unreachable => "到達不可",
        _ => "不明",
    };
}

internal static class Ports
{
    /// <summary>Find the PID listening on a local TCP port using netstat (no admin needed).</summary>
    public static int? ListenerPid(int port)
    {
        try
        {
            var psi = new ProcessStartInfo("netstat", "-ano -p tcp")
            {
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            using var process = Process.Start(psi);
            if (process is null) return null;
            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit(3000);
            foreach (var line in output.Split('\n'))
            {
                if (!line.Contains("LISTENING", StringComparison.OrdinalIgnoreCase)) continue;
                var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length < 5) continue;
                var local = parts[1];
                var colon = local.LastIndexOf(':');
                if (colon < 0) continue;
                if (!int.TryParse(local[(colon + 1)..], out var candidate) || candidate != port) continue;
                if (int.TryParse(parts[^1], out var pid) && pid > 0) return pid;
            }
        }
        catch
        {
            // Port probing is best-effort.
        }
        return null;
    }

    public static async Task<bool> CanConnectAsync(int port, int timeoutMs = 700)
    {
        try
        {
            using var client = new TcpClient();
            using var cts = new CancellationTokenSource(timeoutMs);
            await client.ConnectAsync("127.0.0.1", port, cts.Token);
            return true;
        }
        catch
        {
            return false;
        }
    }

    public static async Task<bool> WaitUntilListeningAsync(int port, int timeoutMs)
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (DateTime.UtcNow < deadline)
        {
            if (await CanConnectAsync(port, 400)) return true;
            await Task.Delay(400);
        }
        return false;
    }

    public static async Task<bool> WaitUntilClosedAsync(int port, int timeoutMs)
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (DateTime.UtcNow < deadline)
        {
            if (!await CanConnectAsync(port, 300)) return true;
            await Task.Delay(300);
        }
        return false;
    }
}



