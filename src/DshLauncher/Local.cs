using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace DshLauncher;

/// <summary>Local machine control: dsh web process lifecycle and status.</summary>
internal static class Local
{
    public static string DshCommand()
    {
        var cmd = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm", "dsh.cmd");
        return File.Exists(cmd) ? cmd : "dsh";
    }

    public static string StartCommandLine(Machine machine) =>
        $"dsh {machine.Profile} --port {machine.Port} --no-open";

    public static string LogPath(Machine machine)
    {
        var dir = DataDir("logs");
        return Path.Combine(dir, $"{machine.Id}.log");
    }

    public static string RunScriptPath(Machine machine) => Path.Combine(DataDir("run"), $"{machine.Id}.cmd");

    /// <summary>Hidden launcher: wscript starts the run script with no console window.</summary>
    public static string HiddenLauncherPath(Machine machine) => Path.Combine(DataDir("run"), $"{machine.Id}.vbs");

    private static string DataDir(string name)
    {
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "DshLauncher", name);
        Directory.CreateDirectory(dir);
        return dir;
    }

    public static async Task<MachineStatus> StatusAsync(Machine machine)
    {
        var status = new MachineStatus
        {
            Port = machine.Port,
            Url = machine.TargetUrl,
            Command = StartCommandLine(machine),
            Platform = "Windows",
        };

        var pid = Ports.ListenerPid(machine.Port);
        status.PortOpen = pid is not null;
        if (pid is null)
        {
            status.State = MachineState.Stopped;
            return status;
        }

        status.State = MachineState.Running;
        status.Pid = pid;
        try
        {
            using var process = Process.GetProcessById(pid.Value);
            status.Uptime = DateTime.Now - process.StartTime;
            status.MemoryMb = process.WorkingSet64 / (1024 * 1024);
        }
        catch
        {
            // Start time and memory are optional facts.
        }
        await Task.CompletedTask;
        return status;
    }

    public static async Task<(bool Ok, string Message)> StartAsync(Machine machine, Action<string>? log = null)
    {
        var existing = Ports.ListenerPid(machine.Port);
        if (existing is not null)
            return (true, $"already running (PID {existing})");

        // Run through a small wrapper script so the dsh process owns its stdio
        // (a redirected pipe held by a detached child would hang the caller).
        var script = RunScriptPath(machine);
        var logFile = LogPath(machine);
        var lines = new List<string> { "@echo off" };
        foreach (var pair in machine.Environment)
        {
            lines.Add($"set \"{pair.Key}={pair.Value}\"");
        }
        // Task Scheduler starts the server outside this process, so the User-scope
        // keys start-web.ps1 injects are read back from the registry, never written to disk.
        foreach (var key in new[] { "OPENCODE_GO_API_KEY", "OPENCODE_API_KEY" })
        {
            lines.Add($"for /f \"delims=\" %%A in ('powershell -NoProfile -Command \"[Environment]::GetEnvironmentVariable('{key}','User')\"') do set \"{key}=%%A\"");
        }
        lines.Add("cd /d \"%USERPROFILE%\"");
        lines.Add($"\"{DshCommand()}\" {machine.Profile} --port {machine.Port} --no-open >> \"{logFile}\" 2>&1");
        var content = string.Join("\r\n", lines) + "\r\n";
        var hiddenLauncher = HiddenLauncherPath(machine);
        var vbs = string.Join("\r\n",
            "Set sh = CreateObject(\"WScript.Shell\")",
            $"sh.Run \"\"\"{script}\"\"\", 0, False",
            "") + "\r\n";
        try
        {
            File.WriteAllText(script, content, new UTF8Encoding(false));
            File.WriteAllText(hiddenLauncher, vbs, new UTF8Encoding(false));
        }
        catch (Exception error)
        {
            return (false, $"cannot write run script: {error.Message}");
        }

        // Launch through Task Scheduler: the server then belongs to the Task
        // Scheduler service instead of our process tree, so a caller that pipes
        // `dshl start` output does not wait for the server to exit, and the
        // server survives the launcher closing. wscript keeps the console hidden.
        var taskName = "DshLauncher\\start-" + machine.Id;
        var action = $"wscript.exe \"{hiddenLauncher}\"";
        var created = Run("schtasks", $"/Create /F /TN \"{taskName}\" /TR \"{action}\" /SC ONCE /ST 00:00 /IT", 20_000);
        if (created.Exit != 0)
        {
            return (false, $"cannot create the start task: {created.Output.Trim()}");
        }
        var started = Run("schtasks", $"/Run /TN \"{taskName}\"", 20_000);
        if (started.Exit != 0)
        {
            return (false, $"cannot run the start task: {started.Output.Trim()}");
        }

        log?.Invoke($"started: {StartCommandLine(machine)}");
        var ready = await Ports.WaitUntilListeningAsync(machine.Port, 90_000);
        return ready
            ? (true, $"started (port {machine.Port})")
            : (false, "timed out waiting for the port");
    }

    private static (int Exit, string Output) Run(string file, string arguments, int timeoutMs)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo(file, arguments)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            });
            if (process is null) return (-1, "failed to start " + file);
            var output = process.StandardOutput.ReadToEnd() + process.StandardError.ReadToEnd();
            process.WaitForExit(timeoutMs);
            return (process.HasExited ? process.ExitCode : -2, output);
        }
        catch (Exception error)
        {
            return (-1, error.Message);
        }
    }

    public static async Task<(bool Ok, string Message)> StopAsync(Machine machine)
    {
        var pid = Ports.ListenerPid(machine.Port);
        if (pid is null) return (true, "already stopped");

        try
        {
            using var kill = Process.Start(new ProcessStartInfo("taskkill", $"/PID {pid} /T /F")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            });
            kill?.WaitForExit(15_000);
        }
        catch (Exception error)
        {
            return (false, error.Message);
        }

        var closed = await Ports.WaitUntilClosedAsync(machine.Port, 20_000);
        if (!closed) return (false, "port still in use");

        // Clean up the one-shot task and any wrapper process left from an older
        // run (for example a visible console started before the hidden launcher).
        Run("schtasks", $"/Delete /F /TN \"DshLauncher\\start-{machine.Id}\"", 10_000);
        var scriptPath = RunScriptPath(machine);
        var ps = "Get-CimInstance Win32_Process -Filter \"Name='cmd.exe'\" | Where-Object { $_.CommandLine -like '*" +
                 scriptPath + "*' } | ForEach-Object { taskkill /PID $_.ProcessId /T /F | Out-Null }";
        Run("powershell", "-NoProfile -ExecutionPolicy Bypass -EncodedCommand " +
                          Convert.ToBase64String(Encoding.Unicode.GetBytes(ps)), 15_000);
        return (true, "stopped");
    }

    public static async Task<(bool Ok, string Message)> RestartAsync(Machine machine, Action<string>? log = null)
    {
        var stopped = await StopAsync(machine);
        if (!stopped.Ok) return stopped;
        return await StartAsync(machine, log);
    }

    public static string[] Tail(Machine machine, int lines)
    {
        try
        {
            var path = LogPath(machine);
            if (!File.Exists(path)) return Array.Empty<string>();
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            using var reader = new StreamReader(stream, Encoding.UTF8);
            var all = new List<string>();
            while (reader.ReadLine() is { } line) all.Add(line);
            return all.Count <= lines ? all.ToArray() : all.Skip(all.Count - lines).ToArray();
        }
        catch
        {
            return Array.Empty<string>();
        }
    }
}



