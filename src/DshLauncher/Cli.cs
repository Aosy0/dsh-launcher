using System.IO;
using System.Threading;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Text.Json;

namespace DshLauncher;

/// <summary>One entry point for machine status and lifecycle used by both CLI and UI.</summary>
internal static class MachineOps
{
    public static async Task<MachineStatus> StatusAsync(Machine machine)
    {
        var status = machine.Kind == MachineKind.Local
            ? await Local.StatusAsync(machine)
            : await Remote.StatusAsync(machine);
        if (machine.Kind == MachineKind.Ssh && machine.Platform == "auto" && status.Platform is not null)
        {
            machine.Platform = status.Platform.ToLowerInvariant();
        }
        status.Command = DisplayCommand(machine, machine.Kind == MachineKind.Local ? "restart" : "status");
        return status;
    }

    public static string DisplayCommand(Machine machine, string verb)
    {
        if (machine.Kind == MachineKind.Local) return Local.StartCommandLine(machine);
        return Remote.ActionCommand(machine, verb);
    }

    public static async Task<(bool Ok, string Message)> ActionAsync(Machine machine, string verb)
    {
        if (machine.Kind == MachineKind.Local)
        {
            return verb switch
            {
                "start" => await Local.StartAsync(machine),
                "stop" => await Local.StopAsync(machine),
                _ => await Local.RestartAsync(machine),
            };
        }
        return await Remote.ActionAsync(machine, verb);
    }

    public static Task<(bool Ok, string Message)> DeployAsync(Machine machine) =>
        machine.Kind == MachineKind.Local
            ? Task.FromResult((true, "local machine needs no helper"))
            : Remote.DeployAsync(machine);

    public static Task<RemoteSetup.Result> SetupFullAsync(Machine machine, IProgress<string>? progress = null) =>
        machine.Kind == MachineKind.Local
            ? Task.FromResult(new RemoteSetup.Result(false, "local machine needs no setup", Array.Empty<RemoteSetup.Step>(), Array.Empty<string>()))
            : RemoteSetup.RunAsync(machine, progress);

    public static Task<string[]> TailAsync(Machine machine, int lines) =>
        machine.Kind == MachineKind.Local
            ? Task.FromResult(Local.Tail(machine, lines))
            : Remote.TailAsync(machine, lines);
}

internal static class Cli
{
    private sealed class Options
    {
        public bool Json;
        public bool All;
        public bool Yes;
        public bool DryRun;
        public bool Install;
        public bool Open;
        public bool Copy;
        public bool Check;
        public string? Config;
        public int Lines = 50;
        public List<string> Positionals = new();
    }

    public static int Run(string[] args)
    {
        // The option loop rejects unknown flags, so answer version flags first.
        if (args.Contains("--version") || args.Contains("-V"))
        {
            Console.WriteLine(AppInfo.Version);
            return 0;
        }

        var options = new Options();
        var positionals = new List<string>();
        for (var i = 0; i < args.Length; i++)
        {
            var arg = args[i];
            switch (arg)
            {
                case "--json": options.Json = true; break;
                case "--all": options.All = true; break;
                case "--yes" or "-y": options.Yes = true; break;
                case "--dry-run": options.DryRun = true; break;
                case "--install": options.Install = true; break;
                case "--open": options.Open = true; break;
                case "--copy": options.Copy = true; break;
                case "--check": options.Check = true; break;
                case "--config" when i + 1 < args.Length: options.Config = args[++i]; break;
                case "-n" when i + 1 < args.Length && int.TryParse(args[i + 1], out var lines):
                    options.Lines = lines; i++; break;
                case "-h" or "--help": PrintHelp(); return 0;
                default:
                    if (arg.StartsWith('-')) { Fail($"unknown option: {arg}"); return 1; }
                    positionals.Add(arg);
                    break;
            }
        }
        options.Positionals = positionals;

        if (args.Contains("--version") || (positionals.Count == 1 && positionals[0] == "version"))
        {
            Console.WriteLine(AppInfo.Version);
            return 0;
        }

        try
        {
            var config = LauncherConfig.Load(options.Config);
            var command = positionals.FirstOrDefault() ?? "status";
            var target = positionals.Skip(1).FirstOrDefault();
            var code = command switch
            {
                "status" => Status(config, options, target),
                "machines" or "list" => List(config, options),
                "start" or "stop" or "restart" => Action(config, options, command, target),
                "url" => Url(config, options, target),
                "logs" => Logs(config, options, target),
                "setup" => Setup(config, options, target),
                "rename" => Rename(config, options, target, positionals.Skip(2).FirstOrDefault()),
                "add" => Add(config, options, target, positionals.Skip(2).FirstOrDefault(), positionals.Skip(3).FirstOrDefault()),
                "remove" or "rm" => Remove(config, options, target),
                "open" => Open(config, options, target),
                "pwa" => Pwa(config, options),
                "auth-url" or "token" => AuthUrl(config, options, target),
                "update" => Update(options),
                "gui" => 0,
                _ => Unknown(command),
            };
            if (positionals.Count > 0 || options.Config is not null) config.Save(options.Config);
            return code;
        }
        catch (Exception error)
        {
            Fail(error.Message);
            return 1;
        }
    }

    private static int Status(LauncherConfig config, Options options, string? target)
    {
        var machines = target is null
            ? config.Machines.ToList()
            : new List<Machine> { Resolve(config, target) };

        var statuses = new List<MachineStatus>();
        foreach (var machine in machines)
        {
            var status = MachineOps.StatusAsync(machine).GetAwaiter().GetResult();
            if (statuses.Count == 0 || machine.Kind == MachineKind.Local) statuses.Add(status);
            else statuses.Add(status);
        }

        if (options.Json)
        {
            var payload = machines.Zip(statuses).Select(pair => new
            {
                id = pair.First.Id,
                name = pair.First.Name,
                displayName = pair.First.DisplayName,
                kind = pair.First.Kind.ToString().ToLowerInvariant(),
                platform = pair.First.Platform,
                state = pair.Second.StateText,
                pid = pair.Second.Pid,
                port = pair.Second.Port,
                uptimeSeconds = pair.Second.Uptime?.TotalSeconds,
                memoryMb = pair.Second.MemoryMb,
                url = pair.Second.Url,
                note = pair.Second.Note,
                nodeVersion = pair.Second.NodeVersion,
                dshInstalled = pair.Second.DshInstalled,
                error = pair.Second.Error,
                latencyMs = pair.Second.LatencyMs,
                command = pair.Second.Command,
            });
            Console.WriteLine(JsonSerializer.Serialize(payload, Json.Options));
            return ExitCode(statuses);
        }

        foreach (var machine in machines)
        {
            var status = statuses[machines.IndexOf(machine)];
            var name = machine.DisplayName.PadRight(22);
            var details = new List<string> { status.StateText };
            if (status.Pid is not null) details.Add($"PID {status.Pid}");
            if (status.Uptime is not null) details.Add(status.Uptime.Value.ToString(@"h\:mm\:ss"));
            if (status.MemoryMb is not null) details.Add($"{status.MemoryMb} MB");
            if (status.LatencyMs is not null) details.Add($"{status.LatencyMs} ms");
            if (status.Note is not null) details.Add(status.Note);
            if (status.Error is not null) details.Add(status.Error);
            Console.WriteLine($"{name}{string.Join("  ", details)}");
        }
        return ExitCode(statuses);
    }

    private static int List(LauncherConfig config, Options options)
    {
        if (options.Json)
        {
            var payload = config.Machines.Select(m => new
            {
                id = m.Id,
                name = m.Name,
                displayName = m.DisplayName,
                kind = m.Kind.ToString().ToLowerInvariant(),
                platform = m.Platform,
                sshAlias = m.SshAlias,
                profile = m.Profile,
                port = m.Port,
                url = m.Url,
                pinned = m.Pinned,
            });
            Console.WriteLine(JsonSerializer.Serialize(payload, Json.Options));
            return 0;
        }
        foreach (var machine in config.Machines)
        {
            var platform = machine.Kind == MachineKind.Ssh ? $" {machine.Platform}" : string.Empty;
            Console.WriteLine($"{machine.DisplayName}  ({machine.Id})  port {machine.Port}{platform}");
        }
        return 0;
    }

    private static int Action(LauncherConfig config, Options options, string verb, string? target)
    {
        var machine = Resolve(config, target);
        if (options.DryRun)
        {
            Console.WriteLine(MachineOps.DisplayCommand(machine, verb));
            return 0;
        }
        var (ok, message) = MachineOps.ActionAsync(machine, verb).GetAwaiter().GetResult();
        if (options.Json)
        {
            Console.WriteLine(JsonSerializer.Serialize(new { machine = machine.Id, action = verb, ok, message }, Json.Options));
        }
        else
        {
            Console.WriteLine($"{machine.DisplayName}: {verb} -> {(ok ? "ok" : "failed")} ({message})");
        }
        if (!ok && message.StartsWith("needs setup", StringComparison.OrdinalIgnoreCase)) return 4;
        return ok ? 0 : 1;
    }

    private static int Url(LauncherConfig config, Options options, string? target)
    {
        var machine = Resolve(config, target);
        Console.WriteLine(machine.TargetUrl);
        return 0;
    }

    private static int Logs(LauncherConfig config, Options options, string? target)
    {
        var machine = Resolve(config, target);
        var lines = MachineOps.TailAsync(machine, options.Lines).GetAwaiter().GetResult();
        foreach (var line in lines) Console.WriteLine(line);
        return 0;
    }

    private static int Setup(LauncherConfig config, Options options, string? target)
    {
        var machine = Resolve(config, target);
        if (machine.Kind == MachineKind.Local) { Console.WriteLine("local machine needs no helper"); return 0; }
        if (!options.Install)
        {
            var (ok, message) = MachineOps.DeployAsync(machine).GetAwaiter().GetResult();
            Console.WriteLine(ok ? $"installed: {message}" : $"failed: {message}");
            return ok ? 0 : 1;
        }
        if (options.DryRun)
        {
            foreach (var line in RemoteSetup.Plan(machine)) Console.WriteLine(line);
            return 0;
        }
        var result = RemoteSetup.RunAsync(machine, new Progress<string>(line => Console.Error.WriteLine(line))).GetAwaiter().GetResult();
        if (options.Json)
        {
            Console.WriteLine(JsonSerializer.Serialize(new { machine = machine.Id, ok = result.Ok, message = result.Message, steps = result.Steps }, Json.Options));
        }
        else
        {
            foreach (var step in result.Steps) Console.WriteLine($"{step.Name}: {step.State} {step.Detail}");
            Console.WriteLine(result.Message);
        }
        return result.Ok ? 0 : 1;
    }

    private static int Rename(LauncherConfig config, Options options, string? target, string? name)
    {
        if (string.IsNullOrWhiteSpace(target) || string.IsNullOrWhiteSpace(name))
        {
            Fail("usage: dshl rename <machine> <name>");
            return 1;
        }
        var machine = Resolve(config, target);
        machine.Name = name.Trim();
        config.Save(options.Config);
        Console.WriteLine($"{machine.Id}: {machine.DisplayName}");
        return 0;
    }

    private static int Add(LauncherConfig config, Options options, string? name, string? alias, string? platform)
    {
        if (string.IsNullOrWhiteSpace(name) || string.IsNullOrWhiteSpace(alias))
        {
            Fail("usage: dshl add <name> <ssh-alias> [platform]");
            return 1;
        }
        var id = name.Trim();
        if (config.Find(id) is not null && config.Machines.Any(m => m.Id == id))
        {
            Fail($"machine already exists: {id}");
            return 1;
        }
        var machine = new Machine
        {
            Id = id,
            Kind = MachineKind.Ssh,
            Name = name.Trim(),
            SshAlias = alias.Trim(),
            Platform = string.IsNullOrWhiteSpace(platform) ? "auto" : platform.Trim().ToLowerInvariant(),
            Profile = "web",
            Port = 3080,
        };
        config.Machines.Add(machine);
        config.Save(options.Config);
        Console.WriteLine($"added {machine.DisplayName}");
        return 0;
    }

    private static int Remove(LauncherConfig config, Options options, string? target)
    {
        var machine = Resolve(config, target);
        if (machine.Kind == MachineKind.Local) { Fail("the local machine cannot be removed"); return 1; }
        config.Machines.Remove(machine);
        config.Save(options.Config);
        Console.WriteLine($"removed {machine.DisplayName}");
        return 0;
    }

    private static int Open(LauncherConfig config, Options options, string? target)
    {
        var machine = Resolve(config, target);
        if (options.DryRun)
        {
            Console.WriteLine(machine.TargetUrl);
            return 0;
        }
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(machine.TargetUrl) { UseShellExecute = true });
        Console.WriteLine(machine.TargetUrl);
        return 0;
    }

    /// <summary>This PC's DSH as an installed browser web app (PWA): detection info, command receipt, or open.</summary>
    private static int Pwa(LauncherConfig config, Options options)
    {
        var local = config.LocalMachine;
        var installations = BrowserApps.Installations();
        var browsers = installations.Select(installation => installation.Label).ToArray();
        var app = BrowserApps.Find(local);

        if (app is null)
        {
            var browserFound = installations.Count > 0;
            var hint = browserFound
                ? "ブラウザでこの URL を開き、「アプリとしてインストール」で追加します（Chromium 系のブラウザが必要です）。"
                : "PWA に対応したブラウザが見つかりません。Chromium 系のブラウザをインストールしてください。";
            if (options.Json)
            {
                Console.WriteLine(JsonSerializer.Serialize(new
                {
                    machine = local.Id,
                    url = local.TargetUrl,
                    browserFound,
                    browsers,
                    installed = false,
                    hint,
                }, Json.Options));
            }
            else
            {
                Console.WriteLine(browserFound
                    ? $"PWA はインストールされていません: {local.TargetUrl}"
                    : "PWA に対応したブラウザが見つかりません");
                Console.WriteLine($"hint: {hint}");
            }
            return 4;
        }

        if (options.DryRun)
        {
            Console.WriteLine(app.CommandLine);
            return 0;
        }

        if (!options.Open)
        {
            var knownAuthenticated = PwaAuth.KnownAuthenticated(app);
            var authAvailable = PwaAuth.CanAuthenticate(local, app);
            if (options.Json)
            {
                Console.WriteLine(JsonSerializer.Serialize(new
                {
                    machine = local.Id,
                    url = local.TargetUrl,
                    manifestId = app.ManifestId,
                    installed = true,
                    appId = app.AppId,
                    name = app.Label,
                    browser = app.Browser,
                    browsers,
                    profile = app.ProfileDirectory,
                    command = app.CommandLine,
                    authenticated = knownAuthenticated,
                    authAvailable,
                }, Json.Options));
            }
            else
            {
                Console.WriteLine($"{app.Label}  {app.AppId}  {app.ProfileDirectory}  {local.TargetUrl}");
                Console.WriteLine(app.CommandLine);
                if (knownAuthenticated is true) Console.WriteLine("認証: 済み");
                else if (authAvailable) Console.WriteLine("認証: 未確認（--open で自動認証できます）");
                else Console.WriteLine("認証: 自動認証の対象外（127.0.0.1 の PWA / .credentials.yaml が必要です）");
            }
            return 0;
        }

        var result = PwaAuth.OpenAsync(local, app, line => Console.Error.WriteLine(line)).GetAwaiter().GetResult();
        if (options.Json)
        {
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                machine = local.Id,
                appId = app.AppId,
                name = app.Label,
                browser = app.Browser,
                profile = app.ProfileDirectory,
                command = app.CommandLine,
                ok = result.Ok,
                authenticated = result.Authenticated,
                authUrlIssued = result.AuthUrlIssued,
                message = result.Message,
            }, Json.Options));
        }
        else
        {
            Console.WriteLine(result.Ok ? result.Message : $"failed: {result.Message}");
        }
        return result.Ok ? 0 : 1;
    }

    /// <summary>Issues the `?token=` URL that authenticates a new browser (local DSH only).</summary>
    private static int AuthUrl(LauncherConfig config, Options options, string? target)
    {
        var machine = Resolve(config, target);
        var info = AuthUrls.IssueAsync(machine).GetAwaiter().GetResult();

        if (info.Ok)
        {
            if (options.Copy) CopyToClipboard(info.Url);
            if (options.Open) OpenInBrowser(info.Url);
        }

        if (options.Json)
        {
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                machine = machine.Id,
                ok = info.Ok,
                url = info.Url,
                localUrl = info.LocalUrl,
                externalUrl = info.ExternalUrl,
                token = info.Token,
                pid = info.Pid,
                message = info.Message,
            }, Json.Options));
            return info.Ok ? 0 : 1;
        }

        if (!info.Ok)
        {
            Fail(info.Message);
            return 1;
        }

        Console.WriteLine(info.Url);
        return 0;
    }

    private static void CopyToClipboard(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return;
        try { System.Windows.Clipboard.SetText(text); }
        catch (Exception error) { Fail($"cannot copy the URL: {error.Message}"); }
    }

    private static void OpenInBrowser(string? url)
    {
        if (string.IsNullOrWhiteSpace(url)) return;
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception error) { Fail($"cannot open the browser: {error.Message}"); }
    }

    /// <summary>Checks GitHub Releases and updates this exe in place (restarting it).</summary>
    private static int Update(Options options)
    {
        var info = Updater.CheckAsync().GetAwaiter().GetResult();
        if (info is null)
        {
            Fail("最新バージョンを確認できませんでした（ネットワーク接続を確認してください）");
            return 1;
        }

        if (!info.IsNewer)
        {
            if (options.Json)
            {
                Console.WriteLine(JsonSerializer.Serialize(new
                {
                    current = AppInfo.Version,
                    latest = info.Version,
                    available = false,
                }, Json.Options));
            }
            else
            {
                Console.WriteLine($"最新版です（{AppInfo.Version}）");
            }
            return 2;
        }

        if (options.Check || options.DryRun)
        {
            if (options.Json)
            {
                Console.WriteLine(JsonSerializer.Serialize(new
                {
                    current = AppInfo.Version,
                    latest = info.Version,
                    available = true,
                    asset = info.AssetName,
                    assetBytes = info.AssetSize,
                    url = info.AssetUrl,
                    target = Updater.CurrentExePath,
                }, Json.Options));
            }
            else
            {
                Console.WriteLine($"v{info.Version} が利用可能です（現在 {AppInfo.Version}）");
                Console.WriteLine($"{info.AssetName}  {info.AssetSize / 1048576.0:0.0} MB");
                if (options.DryRun) Console.WriteLine($"target: {Updater.CurrentExePath}");
            }
            return 0;
        }

        var progress = new Progress<(string Phase, double? Percent)>(value =>
        {
            if (value.Percent is double percent) Console.Error.Write($"\r{value.Phase} {percent:0}%   ");
            else Console.Error.Write($"\r{value.Phase}   ");
        });
        var result = Updater.InstallAsync(info, progress).GetAwaiter().GetResult();
        Console.Error.WriteLine();
        if (options.Json)
        {
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                current = AppInfo.Version,
                latest = info.Version,
                asset = info.AssetName,
                ok = result.Ok,
                message = result.Message,
            }, Json.Options));
        }
        else
        {
            Console.WriteLine(result.Ok ? result.Message : $"failed: {result.Message}");
        }
        return result.Ok ? 0 : 1;
    }

    private static int Unknown(string command)
    {
        Fail($"unknown command: {command}");
        PrintHelp();
        return 1;
    }

    private static Machine Resolve(LauncherConfig config, string? target)
    {
        if (string.IsNullOrWhiteSpace(target)) return config.LocalMachine;
        return config.Find(target) ?? throw new InvalidOperationException($"machine not found: {target}");
    }

    private static int ExitCode(IEnumerable<MachineStatus> statuses)
    {
        var list = statuses.ToList();
        if (list.Any(s => s.State == MachineState.NeedsSetup)) return 4;
        if (list.Any(s => s.State == MachineState.Unreachable)) return 3;
        return 0;
    }

    private static void Fail(string message) => Console.Error.WriteLine($"dshl: {message}");

    private static void PrintHelp()
    {
        Console.WriteLine("""
dshl — DeepSeek Harness launcher

usage:
  dshl status [machine] [--all] [--json]
  dshl start|stop|restart [machine] [--yes] [--dry-run] [--json]
  dshl machines [--json]
  dshl url [machine]
  dshl logs [machine] [-n 50]
  dshl setup [machine] [--install] [--dry-run]
                                deploy the helper, or install Node 24.9+ and dsh
  dshl rename <machine> <name>
  dshl add <name> <ssh-alias> [linux|windows]
  dshl remove <machine>
  dshl open [machine] [--dry-run]
                                open the URL in the default browser
  dshl pwa [--open] [--dry-run] [--json]
                                this PC's DSH as an installed browser web app (PWA):
                                info, or --open to launch it (--dry-run prints the command line)
  dshl auth-url [machine] [--copy] [--open] [--json]
                                issue the ?token= URL that authenticates a new browser
                                (this PC's DSH; the URL is valid while dsh runs)
  dshl gui                      open the launcher window
  dshl update [--check] [--dry-run] [--json]
                                check GitHub Releases and update this exe in place
                                (--check: report only; --dry-run: print the plan)
  --config <path>               use a different hosts.json

exit codes: 0 ok / 1 error / 2 no change / 3 unreachable / 4 needs setup (helper / PWA)
""");
    }
}







