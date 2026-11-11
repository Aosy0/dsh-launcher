using System.IO;
using System.Threading;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace DshLauncher;

/// <summary>SSH transport for remote machines.</summary>
internal static class Ssh
{
    public static IEnumerable<string> Aliases()
    {
        var config = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh", "config");
        if (!File.Exists(config)) yield break;
        foreach (var raw in File.ReadAllLines(config))
        {
            var line = raw.Trim();
            if (!line.StartsWith("Host ", StringComparison.OrdinalIgnoreCase)) continue;
            var name = line[5..].Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
            if (string.IsNullOrEmpty(name)) continue;
            if (name.Contains('*') || name.Contains('?') || name.Equals("github.com", StringComparison.OrdinalIgnoreCase)) continue;
            yield return name;
        }
    }

    public static async Task<(int Exit, string Stdout, string Stderr)> RunAsync(
        string alias, string command, int timeoutSeconds = 20, string? stdin = null)
    {
        var psi = new ProcessStartInfo("ssh")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = stdin is not null,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var arg in new[]
                 {
                     "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=accept-new",
                     alias, command,
                 })
        {
            psi.ArgumentList.Add(arg);
        }

        try
        {
            using var process = new Process { StartInfo = psi };
            if (!process.Start()) return (-1, "", "failed to start ssh");
            if (stdin is not null)
            {
                await process.StandardInput.WriteAsync(stdin);
                process.StandardInput.Close();
            }
            var stdout = process.StandardOutput.ReadToEndAsync();
            var stderr = process.StandardError.ReadToEndAsync();
            var finished = await Task.WhenAny(Task.Run(() => process.WaitForExit()), Task.Delay(timeoutSeconds * 1000));
            if (finished is not Task<int> && !process.HasExited)
            {
                try { process.Kill(true); } catch { }
                return (-2, "", $"timeout after {timeoutSeconds}s");
            }
            process.WaitForExit();
            return (process.ExitCode, await stdout, await stderr);
        }
        catch (Exception error)
        {
            return (-1, "", error.Message);
        }
    }

    public static Task<(int Exit, string Stdout, string Stderr)> RunPowerShellAsync(
        string alias, string script, int timeoutSeconds = 30)
    {
        var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
        return RunAsync(alias, $"powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand {encoded}", timeoutSeconds);
    }
}

/// <summary>Remote machine status and control through SSH and a small audit-able helper.</summary>
internal static class Remote
{
    public static string StatusCommand(Machine machine) =>
        $"ssh {machine.SshAlias} 'uname -s; node -v; command -v dsh; ls ~/.dsh'";

    public static string ActionCommand(Machine machine, string verb) =>
        machine.Platform == "windows"
            ? $"ssh {machine.SshAlias} 'powershell -NoProfile -File ~/.dsh/dshl/agent.ps1 -Verb {verb}'"
            : $"ssh {machine.SshAlias} 'sh ~/.dsh/dshl/agent.sh {verb}'";

    public static async Task<MachineStatus> StatusAsync(Machine machine)
    {
        var alias = machine.SshAlias ?? machine.Id;
        var status = new MachineStatus
        {
            Port = machine.Port,
            Url = machine.TargetUrl,
            Command = StatusCommand(machine),
        };
        var watch = Stopwatch.StartNew();

        var probe = string.Join("; ",
            "PATH=\"$HOME/.dsh/npm-global/bin:$HOME/.dsh/runtime/node/bin:$HOME/.local/bin:$HOME/.npm-global/bin:$PATH\"",
            "for p in \"$HOME\"/.nvm/versions/node/*/bin; do [ -d \"$p\" ] && PATH=\"$p:$PATH\"; done",
            "export PATH",
            "uname -s 2>/dev/null",
            "node -v 2>/dev/null",
            "command -v dsh 2>/dev/null || echo NO_DSH",
            "[ -d \"$HOME/.dsh\" ] && echo DSH_HOME || echo NO_DSH_HOME",
            "if command -v ss >/dev/null 2>&1; then ss -ltn 2>/dev/null; else netstat -ltn 2>/dev/null; fi | grep -q ':" + machine.Port + " ' && echo PORT_OPEN || echo PORT_CLOSED",
            "if [ -f \"$HOME/.dsh/dshl/agent.sh\" ]; then sh \"$HOME/.dsh/dshl/agent.sh\" status 2>/dev/null; fi");

        var result = await Ssh.RunAsync(alias, probe, 15);
        status.LatencyMs = watch.ElapsedMilliseconds;

        if (result.Stdout.Contains("Linux", StringComparison.Ordinal))
        {
            status.Platform = "Linux";
            ApplyPosixProbe(status, result.Stdout);
        }
        else if (result.Stdout.Contains("Darwin", StringComparison.Ordinal))
        {
            status.Platform = "macOS";
            ApplyPosixProbe(status, result.Stdout);
        }
        else
        {
            var windows = await ProbeWindowsAsync(machine, alias);
            if (windows is null)
            {
                status.State = MachineState.Unreachable;
                status.Error = string.IsNullOrWhiteSpace(result.Stderr) ? "ssh probe failed" : result.Stderr.Trim();
                return status;
            }
            status.Platform = "Windows";
            ApplyWindowsProbe(status, windows);
        }

        if (status.DshInstalled != true || !IsNodeSupported(status.NodeVersion))
        {
            status.State = MachineState.NeedsSetup;
            status.Note = status.DshInstalled != true
                ? "dsh が見つかりません"
                : $"Node {status.NodeVersion} は 24.9 以上が必要です";
            return status;
        }

        status.State = status.PortOpen == true ? MachineState.Running : MachineState.Stopped;
        return status;
    }

    private static void ApplyPosixProbe(MachineStatus status, string stdout)
    {
        foreach (var raw in stdout.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0) continue;
            if (line.StartsWith("v", StringComparison.Ordinal) && char.IsDigit(line.ElementAtOrDefault(1))) status.NodeVersion = line;
            else if (line.StartsWith("/", StringComparison.Ordinal)) status.DshInstalled = true;
            else if (line == "NO_DSH") status.DshInstalled = false;
            else if (line == "DSH_HOME") status.DshHome = true;
            else if (line == "NO_DSH_HOME") status.DshHome = false;
            else if (line == "PORT_OPEN") status.PortOpen = true;
            else if (line == "PORT_CLOSED") status.PortOpen = false;
            else if (line.StartsWith("{", StringComparison.Ordinal))
            {
                try
                {
                    using var doc = JsonDocument.Parse(line);
                    if (doc.RootElement.TryGetProperty("state", out var state) && state.GetString() == "running")
                    {
                        status.State = MachineState.Running;
                        if (doc.RootElement.TryGetProperty("pid", out var pid) && pid.TryGetInt32(out var parsed)) status.Pid = parsed;
                    }
                }
                catch
                {
                    // Helper output is optional.
                }
            }
        }
    }

    private static async Task<string?> ProbeWindowsAsync(Machine machine, string alias)
    {
        var script = string.Join("; ",
            "$PSVersionTable.PSVersion.Major",
            "'OS=' + $env:OS",
            "'node=' + (node -v 2>$null)",
            "'dsh=' + ((Get-Command dsh -ErrorAction SilentlyContinue).Source)",
            "'home=' + (Test-Path \"$env:USERPROFILE\\.dsh\")",
            "'port=' + ((Get-NetTCPConnection -LocalPort " + machine.Port + " -State Listen -ErrorAction SilentlyContinue | Measure-Object).Count)");
        var result = await Ssh.RunPowerShellAsync(alias, script, 20);
        if (result.Exit != 0 || !result.Stdout.Contains("OS=", StringComparison.Ordinal)) return null;
        return result.Stdout;
    }

    private static void ApplyWindowsProbe(MachineStatus status, string stdout)
    {
        foreach (var raw in stdout.Split('\n'))
        {
            var line = raw.Trim();
            var index = line.IndexOf('=');
            if (index <= 0) continue;
            var key = line[..index];
            var value = line[(index + 1)..].Trim();
            switch (key)
            {
                case "node": status.NodeVersion = value.Length > 0 ? value : null; break;
                case "dsh": status.DshInstalled = value.Length > 0; break;
                case "home": status.DshHome = value.Equals("True", StringComparison.OrdinalIgnoreCase); break;
                case "port": status.PortOpen = !value.Equals("0", StringComparison.Ordinal) && value.Length > 0; break;
            }
        }
    }

    private static bool IsNodeSupported(string? version)
    {
        if (version is null) return false;
        var text = version.TrimStart('v', 'V');
        var parts = text.Split('.');
        if (parts.Length < 2) return false;
        if (!int.TryParse(parts[0], out var major)) return false;
        var minor = int.TryParse(parts[1], out var parsed) ? parsed : 0;
        return major > 24 || (major == 24 && minor >= 9);
    }

    public static async Task<(bool Ok, string Message)> DeployAsync(Machine machine)
    {
        var alias = machine.SshAlias ?? machine.Id;
        var isWindows = machine.Platform == "windows";
        if (isWindows)
        {
            var script = "param()\r\n" +
                         "$dir = Join-Path $env:USERPROFILE '.dsh\\dshl'\r\n" +
                         "New-Item -ItemType Directory -Force -Path $dir | Out-Null\r\n" +
                         "$bytes = [Convert]::FromBase64String('" + Convert.ToBase64String(Ps1Encoding.WithBomUtf8(AgentScripts.Windows)) + "')\r\n" +
                         "[IO.File]::WriteAllBytes((Join-Path $dir 'agent.ps1'), $bytes)\r\n" +
                         "'installed ' + (Join-Path $dir 'agent.ps1')";
            var written = await Ssh.RunPowerShellAsync(alias, script, 30);
            return written.Exit == 0
                ? (true, written.Stdout.Trim())
                : (false, string.IsNullOrWhiteSpace(written.Stderr) ? "failed to write agent.ps1" : written.Stderr.Trim());
        }

        var posix = await Ssh.RunAsync(alias,
            "mkdir -p \"$HOME/.dsh/dshl\" && cat > \"$HOME/.dsh/dshl/agent.sh\" && chmod 700 \"$HOME/.dsh/dshl/agent.sh\" && echo installed",
            30, AgentScripts.Posix);
        return posix.Exit == 0
            ? (true, posix.Stdout.Trim())
            : (false, string.IsNullOrWhiteSpace(posix.Stderr) ? "failed to write agent.sh" : posix.Stderr.Trim());
    }

    public static async Task<(bool Ok, string Message)> ActionAsync(Machine machine, string verb)
    {
        var alias = machine.SshAlias ?? machine.Id;
        (int Exit, string Stdout, string Stderr) result;
        if (machine.Platform == "windows")
        {
            var script = "$s = Join-Path $env:USERPROFILE '.dsh\\dshl\\agent.ps1'; & $s -Verb '" + verb +
                         "' -Port " + machine.Port + " -ProfileName '" + machine.Profile + "'";
            result = await Ssh.RunPowerShellAsync(alias, script, 120);
        }
        else
        {
            result = await Ssh.RunAsync(alias,
                $"DSH_PORT={machine.Port} DSH_PROFILE={machine.Profile} sh \"$HOME/.dsh/dshl/agent.sh\" {verb}", 120);
        }

        if (result.Exit == 4) return (false, "needs setup");
        var lastJson = result.Stdout.Split('\n').LastOrDefault(l => l.TrimStart().StartsWith("{"))?.Trim();
        if (lastJson is not null)
        {
            try
            {
                using var doc = JsonDocument.Parse(lastJson);
                var state = doc.RootElement.TryGetProperty("state", out var s) ? s.GetString() : null;
                return state is "running" or "stopped"
                    ? (true, state)
                    : (false, doc.RootElement.TryGetProperty("reason", out var reason) ? reason.GetString() ?? "failed" : "failed");
            }
            catch
            {
                // Fall through to the raw result.
            }
        }
        return result.Exit == 0
            ? (true, result.Stdout.Trim())
            : (false, string.IsNullOrWhiteSpace(result.Stderr) ? "remote action failed" : result.Stderr.Trim());
    }

    public static async Task<string[]> TailAsync(Machine machine, int lines)
    {
        var alias = machine.SshAlias ?? machine.Id;
        var (exit, stdout, _) = machine.Platform == "windows"
            ? await Ssh.RunPowerShellAsync(alias, $"Get-Content (Join-Path $env:USERPROFILE '.dsh\\dshl\\dsh.log') -Tail {lines} -ErrorAction SilentlyContinue", 20)
            : await Ssh.RunAsync(alias, $"tail -n {lines} \"$HOME/.dsh/dshl/dsh.log\" 2>/dev/null", 20);
        if (exit != 0 || stdout.Length == 0) return Array.Empty<string>();
        return stdout.Replace("\r", "").Split('\n', StringSplitOptions.RemoveEmptyEntries);
    }
}

/// <summary>Remote helper scripts (deployed verbatim, small enough to audit).</summary>
internal static class AgentScripts
{
    public const string Posix = """
#!/bin/sh
# dshl remote agent: manage one dsh web service. Verbs: status|start|stop|restart
DIR="$HOME/.dsh/dshl"
PORT="${DSH_PORT:-3080}"
PROFILE="${DSH_PROFILE:-web}"
PIDF="$DIR/dsh.pid"
LOG="$DIR/dsh.log"
add_paths() {
  PATH="$HOME/.dsh/npm-global/bin:$HOME/.dsh/runtime/node/bin:$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
  for p in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$p" ] && PATH="$p:$PATH"; done
  export PATH
}
add_paths
find_dsh() {
  for c in dsh "$HOME/.dsh/npm-global/bin/dsh" "$HOME/.npm-global/bin/dsh" "$HOME/.local/bin/dsh" "$HOME/.dsh/runtime/node/bin/dsh"; do
    if command -v "$c" >/dev/null 2>&1; then command -v "$c"; return 0; fi
  done
  for p in "$HOME"/.nvm/versions/node/*/bin/dsh; do
    [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}
running_pid() {
  [ -f "$PIDF" ] || return 1
  p=$(cat "$PIDF" 2>/dev/null) || return 1
  [ -n "$p" ] || return 1
  kill -0 "$p" 2>/dev/null || return 1
  printf '%s\n' "$p"
}
port_open() {
  if command -v ss >/dev/null 2>&1; then ss -ltn 2>/dev/null | grep -q ":$PORT "; return $?; fi
  if command -v netstat >/dev/null 2>&1; then netstat -ltn 2>/dev/null | grep -q ":$PORT "; return $?; fi
  return 1
}
do_start() {
  if p=$(running_pid); then printf '{"state":"running","pid":%s,"port":%s}\n' "$p" "$PORT"; return 0; fi
  d=$(find_dsh) || { printf '{"state":"needs-setup","reason":"dsh not found","port":%s}\n' "$PORT"; return 4; }
  mkdir -p "$DIR" || return 1
  cd "$HOME" || return 1
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup "$d" "$PROFILE" --port "$PORT" --no-open >>"$LOG" 2>&1 &
  else
    nohup "$d" "$PROFILE" --port "$PORT" --no-open >>"$LOG" 2>&1 &
  fi
  printf '%s\n' "$!" > "$PIDF"
  i=0
  while [ "$i" -lt 90 ]; do
    if port_open; then printf '{"state":"running","pid":%s,"port":%s}\n' "$(cat "$PIDF")" "$PORT"; return 0; fi
    sleep 1; i=$((i+1))
  done
  printf '{"state":"error","reason":"timeout waiting for port %s"}\n' "$PORT"
  return 1
}
do_stop() {
  if p=$(running_pid); then
    kill -TERM "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null
    sleep 2
    kill -0 "$p" 2>/dev/null && { kill -KILL "-$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null; }
  fi
  rm -f "$PIDF"
  printf '{"state":"stopped","port":%s}\n' "$PORT"
}
case "${1:-status}" in
  status)
    if p=$(running_pid); then printf '{"state":"running","pid":%s,"port":%s}\n' "$p" "$PORT"; else printf '{"state":"stopped","port":%s}\n' "$PORT"; fi ;;
  start) do_start ;;
  stop) do_stop ;;
  restart) do_stop >/dev/null 2>&1; do_start ;;
  *) printf '{"state":"error","reason":"unknown verb"}\n'; exit 1 ;;
esac
""";

    public const string Windows = """
param([string]$Verb = "status", [int]$Port = 3080, [string]$ProfileName = "web")
$ErrorActionPreference = "SilentlyContinue"
$dir = Join-Path $env:USERPROFILE ".dsh\dshl"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$taskName = "DshLauncher\remote-" + $Port
$runCmd = Join-Path $dir ("run-" + $Port + ".cmd")
$runVbs = Join-Path $dir ("run-" + $Port + ".vbs")
$log = Join-Path $dir ("dsh-" + $Port + ".log")
function Get-DshPath {
  # cmd shim first: Get-Command may resolve the .ps1 shim, which cmd.exe cannot run.
  $cmd = Join-Path $env:APPDATA "npm\dsh.cmd"
  if (Test-Path $cmd) { return $cmd }
  $c = Get-Command dsh -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  return $null
}
function Get-ListenerPid {
  $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($conn) { return $conn.OwningProcess }
  return $null
}
function Emit([string]$state, [hashtable]$extra = @{}) {
  $o = [ordered]@{ state = $state; port = $Port }
  foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] }
  ($o | ConvertTo-Json -Compress)
}
function Stop-Dsh {
  $p = Get-ListenerPid
  if ($p) { taskkill /PID $p /T /F | Out-Null }
  schtasks /Delete /F /TN $taskName | Out-Null
  Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" | Where-Object { $_.CommandLine -like ("*run-" + $Port + ".cmd*") } | ForEach-Object { taskkill /PID $_.ProcessId /T /F | Out-Null }
  Emit "stopped"
}
function Start-Dsh {
  $p = Get-ListenerPid
  if ($p) { Emit "running" @{ pid = $p }; return }
  $dsh = Get-DshPath
  if (-not $dsh) { Emit "needs-setup" @{ reason = "dsh not found" }; exit 4 }
  $cmdText = "@echo off`r`ncd /d `"%USERPROFILE%`"`r`n`"$dsh`" $ProfileName --port $Port --no-open >> `"$log`" 2>&1"
  [IO.File]::WriteAllText($runCmd, $cmdText, (New-Object System.Text.UTF8Encoding($false)))
  $vbs = 'Set sh = CreateObject("WScript.Shell")' + "`r`n" + 'sh.Run Chr(34) & "' + $runCmd + '" & Chr(34), 0, False'
  [IO.File]::WriteAllText($runVbs, $vbs, (New-Object System.Text.UTF8Encoding($false)))
  schtasks /Create /F /TN $taskName /TR ("wscript.exe `"" + $runVbs + "`"") /SC ONCE /ST 00:00 /IT | Out-Null
  schtasks /Run /TN $taskName | Out-Null
  $i = 0
  while ($i -lt 90) {
    $now = Get-ListenerPid
    if ($now) { Emit "running" @{ pid = $now }; return }
    Start-Sleep -Seconds 1; $i++
  }
  Emit "error" @{ reason = "timeout waiting for port"; log = $log }
  exit 1
}
switch ($Verb) {
  "status" { $p = Get-ListenerPid; if ($p) { Emit "running" @{ pid = $p } } else { Emit "stopped" } }
  "start" { Start-Dsh }
  "stop" { Stop-Dsh }
  "restart" { Stop-Dsh | Out-Null; Start-Dsh }
  default { Emit "error" @{ reason = "unknown verb" }; exit 1 }
}
""";
}








