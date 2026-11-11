using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace DshLauncher;

/// <summary>Windows PowerShell 5.1 reads .ps1 as ANSI unless the file starts with a UTF-8 BOM.</summary>
internal static class Ps1Encoding
{
    public static byte[] WithBomUtf8(string content)
    {
        var text = Encoding.UTF8.GetBytes(content);
        var bytes = new byte[text.Length + 3];
        bytes[0] = 0xEF;
        bytes[1] = 0xBB;
        bytes[2] = 0xBF;
        text.CopyTo(bytes, 3);
        return bytes;
    }
}

/// <summary>Remote DSH installation: Node 24.9+ and @deepseek-ai/dsh, then the helper.</summary>
internal static class RemoteSetup
{
    public sealed record Step(string Name, string State, string Detail);

    public sealed record Result(bool Ok, string Message, IReadOnlyList<Step> Steps, IReadOnlyList<string> Transcript);

    public static IReadOnlyList<string> Plan(Machine machine) => machine.Platform == "windows"
        ? new[]
        {
            "node -v   (24.9 以上が必要)",
            "npm install -g @deepseek-ai/dsh",
            "dsh --version",
            "~/.dsh/dshl/agent.ps1 を配置",
        }
        : new[]
        {
            "node -v   (24.9 以上が必要。無ければ nvm install 24 / ポータブル Node 24)",
            "npm install -g @deepseek-ai/dsh",
            "dsh --version",
            "~/.dsh/dshl/agent.sh を配置",
        };

    public static async Task<Result> RunAsync(Machine machine, IProgress<string>? progress = null)
    {
        var alias = machine.SshAlias ?? machine.Id;

        // Platform decides which setup dialect to run; the probe also refreshes facts.
        var before = await Remote.StatusAsync(machine);
        if (machine.Platform == "auto" && before.Platform is not null)
            machine.Platform = before.Platform.ToLowerInvariant();
        if (before.State == MachineState.Unreachable)
            return new Result(false, before.Error ?? "ssh で接続できません", Array.Empty<Step>(), Array.Empty<string>());

        var deploy = await Remote.DeployAsync(machine);
        if (!deploy.Ok)
            return new Result(false, "ヘルパーの配置に失敗しました: " + deploy.Message, Array.Empty<Step>(), Array.Empty<string>());

        var transcript = new List<string>();
        var steps = new List<Step>();
        (int Exit, string Stdout, string Stderr) result;
        if (machine.Platform == "windows")
        {
            await WriteWindowsScriptAsync(alias, "setup.ps1", SetupScripts.Windows);
            progress?.Report("セットアップ: Windows 上で npm install を実行しています…");
            result = await Ssh.RunPowerShellAsync(alias,
                "$s = Join-Path $env:USERPROFILE '.dsh\\dshl\\setup.ps1'; & $s *>&1 | ForEach-Object { $_.ToString() }", 900);
        }
        else
        {
            var write = await Ssh.RunAsync(alias,
                "mkdir -p \"$HOME/.dsh/dshl\" && cat > \"$HOME/.dsh/dshl/setup.sh\" && chmod 700 \"$HOME/.dsh/dshl/setup.sh\" && echo installed",
                30, SetupScripts.Posix);
            if (write.Exit != 0)
                return new Result(false, "setup.sh の配置に失敗しました", steps, transcript);
            progress?.Report("セットアップ: Node と dsh を導入しています…");
            result = await Ssh.RunAsync(alias, "sh \"$HOME/.dsh/dshl/setup.sh\"", 900);
        }

        foreach (var line in (result.Stdout + "\n" + result.Stderr).Replace("\r", "").Split('\n'))
        {
            var text = line.Trim();
            if (text.Length == 0) continue;
            transcript.Add(text);
            if (!text.StartsWith("{")) continue;
            try
            {
                using var doc = JsonDocument.Parse(text);
                var name = doc.RootElement.TryGetProperty("step", out var step) ? step.GetString() ?? "" : "";
                var state = doc.RootElement.TryGetProperty("state", out var s) ? s.GetString() ?? "" : "";
                var detail = doc.RootElement.TryGetProperty("detail", out var d) ? d.GetString() ?? "" : "";
                steps.Add(new Step(name, state, detail));
                progress?.Report(state == "ok" ? $"{name}: {detail}" : $"{name}: {state} {detail}");
            }
            catch
            {
                // Non-JSON progress lines are kept in the transcript only.
            }
        }

        var failed = steps.FirstOrDefault(step => step.State is "fail" or "error");
        var done = steps.Any(step => step.Name == "done" && step.State == "ok");
        var ok = failed is null && (done || result.Exit == 0);

        // Persist the transcript next to the launcher logs for later inspection.
        try
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "DshLauncher", "logs");
            Directory.CreateDirectory(dir);
            File.WriteAllText(Path.Combine(dir, machine.Id + "-setup.log"), string.Join(Environment.NewLine, transcript), Encoding.UTF8);
        }
        catch
        {
            // The transcript file is best-effort.
        }

        var summary = ok
            ? "セットアップが完了しました"
            : failed is not null
                ? $"{failed.Name}: {failed.Detail}"
                : string.IsNullOrWhiteSpace(result.Stderr) ? "セットアップに失敗しました" : result.Stderr.Trim();

        // Refresh so the UI immediately reflects the new capability.
        if (ok)
        {
            var after = await Remote.StatusAsync(machine);
            if (after.State == MachineState.NeedsSetup)
                summary += "（ただし dsh をまだ検出できません: " + (after.Note ?? "理由不明") + "）";
        }
        return new Result(ok, summary, steps, transcript);
    }

    private static async Task WriteWindowsScriptAsync(string alias, string name, string content)
    {
        var script = "$dir = Join-Path $env:USERPROFILE '.dsh\\dshl'\r\n" +
                     "New-Item -ItemType Directory -Force -Path $dir | Out-Null\r\n" +
                     "$bytes = [Convert]::FromBase64String('" + Convert.ToBase64String(Ps1Encoding.WithBomUtf8(content)) + "')\r\n" +
                     "[IO.File]::WriteAllBytes((Join-Path $dir '" + name + "'), $bytes)\r\n" +
                     "'written'";
        await Ssh.RunPowerShellAsync(alias, script, 30);
    }
}

internal static class SetupScripts
{
    public const string Posix = """
#!/bin/sh
# dshl remote setup: ensure Node 24.9+, install @deepseek-ai/dsh, verify.
set -u
emit() { printf '{"step":"%s","state":"%s","detail":"%s"}\n' "$1" "$2" "$3"; }
node_ok() {
  command -v node >/dev/null 2>&1 || return 1
  node -e 'const v=process.versions.node.split(".").map(Number); process.exit((v[0]>24)||(v[0]===24&&v[1]>=9)?0:1)' >/dev/null 2>&1
}
add_paths() {
  PATH="$HOME/.dsh/npm-global/bin:$HOME/.dsh/runtime/node/bin:$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
  for p in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$p" ] && PATH="$p:$PATH"; done
  export PATH
}
add_paths

if node_ok; then
  emit node ok "$(node -v)"
else
  if [ -s "$HOME/.nvm/nvm.sh" ]; then
    . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1
    nvm install 24 >/dev/null 2>&1
    nvm use 24 >/dev/null 2>&1
    nvm alias default 24 >/dev/null 2>&1
    add_paths
  fi
  if ! node_ok; then
    emit node install "downloading portable Node 24"
    os=$(uname -s); case "$os" in Linux) osn=linux;; Darwin) osn=darwin;; *) emit node fail "unsupported OS: $os"; exit 1;; esac
    arch=$(uname -m); case "$arch" in x86_64|amd64) a=x64;; aarch64|arm64) a=arm64;; *) emit node fail "unsupported arch: $arch"; exit 1;; esac
    dir="$HOME/.dsh/runtime"; mkdir -p "$dir" || { emit node fail "cannot create $dir"; exit 1; }
    sums="$dir/SHASUMS256.txt"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt" -o "$sums" 2>/dev/null
    else
      wget -qO "$sums" "https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt" 2>/dev/null
    fi
    file=$(grep -o "node-v[0-9.]*-$osn-$a.tar.xz" "$sums" 2>/dev/null | head -1)
    [ -n "$file" ] || { emit node fail "cannot resolve Node release"; exit 1; }
    url="https://nodejs.org/dist/latest-v24.x/$file"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$url" -o "$dir/node.tar.xz" 2>/dev/null
    else
      wget -qO "$dir/node.tar.xz" "$url" 2>/dev/null
    fi
    top=$(basename "$file" .tar.xz)
    tar -xJf "$dir/node.tar.xz" -C "$dir" 2>/dev/null || tar -xf "$dir/node.tar.xz" -C "$dir" 2>/dev/null
    rm -rf "$dir/node"
    mv "$dir/$top" "$dir/node" 2>/dev/null || { emit node fail "cannot extract Node"; exit 1; }
    add_paths
  fi
  if node_ok; then emit node ok "$(node -v)"; else emit node fail "Node 24.9+ installation failed"; exit 1; fi
fi

if command -v dsh >/dev/null 2>&1; then
  emit dsh ok "$(dsh --version 2>/dev/null || echo installed)"
else
  emit dsh install "npm install -g @deepseek-ai/dsh"
  npm install -g @deepseek-ai/dsh@latest >/dev/null 2>&1 || npm install -g --prefix "$HOME/.dsh/npm-global" @deepseek-ai/dsh@latest >/dev/null 2>&1
  add_paths
  if command -v dsh >/dev/null 2>&1; then
    emit dsh ok "$(dsh --version 2>/dev/null || echo installed)"
  else
    emit dsh fail "dsh installation failed"
    exit 1
  fi
fi

emit done ok "ready"
""";

    public const string Windows = """
param()
$ErrorActionPreference = "Continue"
function Emit([string]$step, [string]$state, [string]$detail) {
  Write-Output (ConvertTo-Json -Compress -InputObject ([ordered]@{ step = $step; state = $state; detail = $detail }))
}
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { Emit "node" "fail" "Node 24.9+ not found"; exit 1 }
$version = (& node -v) 2>$null
$parts = $version.TrimStart('v').Split('.')
$major = [int]$parts[0]; $minor = [int]$parts[1]
if ($major -lt 24 -or ($major -eq 24 -and $minor -lt 9)) { Emit "node" "fail" "Node $version is too old (24.9+ required)"; exit 1 }
Emit "node" "ok" $version
$dsh = Get-Command dsh -ErrorAction SilentlyContinue
if ($dsh) {
  Emit "dsh" "ok" ((& dsh --version) 2>$null)
} else {
  Emit "dsh" "install" "npm install -g @deepseek-ai/dsh"
  & npm install -g @deepseek-ai/dsh@latest *> $null
  $dsh = Get-Command dsh -ErrorAction SilentlyContinue
  if (-not $dsh) {
    $candidate = Join-Path $env:APPDATA "npm\dsh.cmd"
    if (Test-Path $candidate) { $dsh = $candidate }
  }
  if (-not $dsh) { Emit "dsh" "fail" "dsh installation failed"; exit 1 }
  Emit "dsh" "ok" ((& $dsh --version) 2>$null)
}
Emit "done" "ok" "ready"
""";
}




