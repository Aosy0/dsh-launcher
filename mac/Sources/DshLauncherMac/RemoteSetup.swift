import Foundation

/// Remote DSH installation: Node 24.9+ and @deepseek-ai/dsh, then the helper.
///
/// Ported from the Windows launcher's `Setup.cs`. The POSIX script already covers macOS
/// (`uname -s` → darwin, including the portable Node 24 tarball under `~/.dsh/runtime`);
/// the only addition is Homebrew on the PATH plus the documented macOS notes.
enum RemoteSetup {
    /// Steps shown in the confirm dialog and `dshl setup --dry-run`.
    static func plan(_ machine: Machine) -> [String] {
        machine.platform == "windows"
            ? [
                "node -v   (24.9 以上が必要)",
                "npm install -g @deepseek-ai/dsh",
                "dsh --version",
                "~/.dsh/dshl/agent.ps1 を配置",
            ]
            : [
                "node -v   (24.9 以上が必要。無ければ nvm install 24 / ポータブル Node 24)",
                "npm install -g @deepseek-ai/dsh",
                "dsh --version",
                "~/.dsh/dshl/agent.sh を配置",
            ]
    }

    /// Run the whole setup: probe (which also decides the dialect), deploy the helper,
    /// write and run `setup.sh`/`setup.ps1`, then parse the step lines.
    static func run(
        _ machine: Machine,
        progress: (@Sendable (String) -> Void)?
    ) async -> SetupOutcome {
        // The probe decides the dialect and refreshes the facts the UI shows. The
        // Windows launcher writes the detected platform back into the shared config
        // object; `Machine` is a value type here, so it stays local to this call and the
        // app persists it from the next status refresh (AppState.refresh).
        var target = machine
        let before = await RemoteMachine.status(machine)
        if target.platform == "auto", let platform = before.platform, !platform.isEmpty {
            target.platform = platform.lowercased()
        }
        if before.state == .unreachable {
            return SetupOutcome(
                ok: false,
                message: before.error ?? "ssh で接続できません",
                steps: [],
                transcript: []
            )
        }

        let deploy = await RemoteMachine.deploy(target)
        guard deploy.0 else {
            return SetupOutcome(
                ok: false,
                message: "ヘルパーの配置に失敗しました: \(deploy.1)",
                steps: [],
                transcript: []
            )
        }

        var transcript: [String] = []
        var steps: [SetupStep] = []
        let result: SshResult

        if target.platform == "windows" {
            let write = await writeWindowsScript(
                machine: target,
                name: "setup.ps1",
                content: SetupScripts.windows
            )
            guard write.0 else {
                return SetupOutcome(
                    ok: false,
                    message: "setup.ps1 の配置に失敗しました: \(write.1)",
                    steps: steps,
                    transcript: transcript
                )
            }
            progress?("セットアップ: Windows 上で npm install を実行しています…")
            let script = [
                "$s = Join-Path $env:USERPROFILE '.dsh\\dshl\\setup.ps1'",
                "& $s *>&1 | ForEach-Object { $_.ToString() }",
            ].joined(separator: "; ")
            result = await SshTransport.runPowerShell(
                alias: target.sshDestination,
                script: script,
                timeout: RemoteTimeouts.setup
            )
        } else {
            let write = await SshTransport.run(
                alias: target.sshDestination,
                command: "mkdir -p \"$HOME/.dsh/dshl\" && cat > \"$HOME/.dsh/dshl/setup.sh\""
                    + " && chmod 700 \"$HOME/.dsh/dshl/setup.sh\" && echo installed",
                timeout: RemoteTimeouts.deploy,
                stdin: SetupScripts.posix
            )
            if write.exit != 0 {
                return SetupOutcome(
                    ok: false,
                    message: "setup.sh の配置に失敗しました",
                    steps: steps,
                    transcript: transcript
                )
            }
            progress?("セットアップ: Node と dsh を導入しています…")
            result = await SshTransport.run(
                alias: target.sshDestination,
                command: "sh \"$HOME/.dsh/dshl/setup.sh\"",
                timeout: RemoteTimeouts.setup
            )
        }

        let output = (result.stdout + "\n" + result.stderr)
            .replacingOccurrences(of: "\r", with: "")
        for raw in output.components(separatedBy: "\n") {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            transcript.append(text)
            // Non-JSON progress lines (npm, tar, curl) stay in the transcript only.
            guard text.hasPrefix("{"), let json = RemoteJSON.object(text) else { continue }
            let name = RemoteJSON.string(json["step"]) ?? ""
            let state = RemoteJSON.string(json["state"]) ?? ""
            let detail = RemoteJSON.string(json["detail"]) ?? ""
            steps.append(SetupStep(name: name, state: state, detail: detail))
            progress?(state == "ok" ? "\(name): \(detail)" : "\(name): \(state) \(detail)")
        }

        let failed = steps.first { $0.state == "fail" || $0.state == "error" }
        let done = steps.contains { $0.name == "done" && $0.state == "ok" }
        let ok = failed == nil && (done || result.exit == 0)

        // Persist the transcript next to the launcher logs for later inspection.
        saveTranscript(transcript, machineId: machine.id)

        var summary: String
        if ok {
            summary = "セットアップが完了しました"
        } else if let failed {
            summary = "\(failed.name): \(failed.detail)"
        } else {
            summary = result.stderrTrimmed.isEmpty
                ? "セットアップに失敗しました"
                : result.stderrTrimmed
        }

        // Refresh so the UI immediately reflects the new capability.
        if ok {
            let after = await RemoteMachine.status(machine)
            if after.state == .needsSetup {
                summary += "（ただし dsh をまだ検出できません: \(after.note ?? "理由不明")）"
            }
        }
        return SetupOutcome(ok: ok, message: summary, steps: steps, transcript: transcript)
    }

    /// Write a `.ps1` on a Windows host: base64 through `[IO.File]::WriteAllBytes`, with
    /// a UTF-8 BOM so PowerShell 5.1 parses the script as UTF-8 (same as Setup.cs).
    private static func writeWindowsScript(
        machine: Machine,
        name: String,
        content: String
    ) async -> (Bool, String) {
        let script = [
            "$dir = Join-Path $env:USERPROFILE '.dsh\\dshl'",
            "New-Item -ItemType Directory -Force -Path $dir | Out-Null",
            "$bytes = [Convert]::FromBase64String('\(ScriptEncoding.base64UTF8BOM(content))')",
            "[IO.File]::WriteAllBytes((Join-Path $dir '\(name)'), $bytes)",
            "'written'",
        ].joined(separator: "\r\n")
        let result = await SshTransport.runPowerShell(
            alias: machine.sshDestination,
            script: script,
            timeout: RemoteTimeouts.deploy
        )
        if result.exit == 0 { return (true, "written") }
        return (false, result.stderrTrimmed.isEmpty ? "failed to write \(name)" : result.stderrTrimmed)
    }

    /// The transcript file is best-effort (the outcome carries the same lines), but it is
    /// what makes a failed setup debuggable after the fact. UTF-8, no BOM.
    private static func saveTranscript(_ lines: [String], machineId: String) {
        do {
            try FileManager.default.createDirectory(
                at: Paths.logsDir,
                withIntermediateDirectories: true
            )
            let file = Paths.logsDir
                .appendingPathComponent(Paths.sanitize(machineId) + "-setup.log")
            try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        } catch {
            // Best-effort: ignoring a full disk or a read-only Application Support folder
            // must not fail an otherwise successful setup.
        }
    }
}

/// Setup scripts. Raw string literals for the same reason as `AgentScripts`: the
/// launcher never interpolates into a script it runs on another host.
enum SetupScripts {
    /// POSIX sh: ensure Node 24.9+, install @deepseek-ai/dsh, verify. Handles Linux and
    /// macOS; the portable Node download uses the darwin tarball. macOS's `/bin/sh` is
    /// bash in POSIX mode, so the nvm block works there.
    static let posix = #"""
    #!/bin/sh
    # dshl remote setup: ensure Node 24.9+, install @deepseek-ai/dsh, verify.
    set -u
    emit() { printf '{"step":"%s","state":"%s","detail":"%s"}\n' "$1" "$2" "$3"; }
    node_ok() {
      command -v node >/dev/null 2>&1 || return 1
      node -e 'const v=process.versions.node.split(".").map(Number); process.exit((v[0]>24)||(v[0]===24&&v[1]>=9)?0:1)' >/dev/null 2>&1
    }
    add_paths() {
      PATH="$HOME/.dsh/npm-global/bin:$HOME/.dsh/runtime/node/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
      for p in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$p" ] && PATH="$p:$PATH"; done
      export PATH
    }
    add_paths

    if node_ok; then
      emit node ok "$(node -v)"
    else
      if [ -s "$HOME/.nvm/nvm.sh" ]; then
        # nvm.sh is bash-only but this script runs under /bin/sh (dash on Debian/Ubuntu,
        # bash 3.2 on macOS). Source it in a subshell: a syntax error or a `set -u`
        # violation there must not abort setup, and add_paths below already picks up the
        # ~/.nvm/versions/node/*/bin that nvm installs into.
        ( . "$HOME/.nvm/nvm.sh"; nvm install 24; nvm alias default 24 ) >/dev/null 2>&1
        add_paths
      fi
      if ! node_ok; then
        emit node install "downloading portable Node 24"
        os=$(uname -s); case "$os" in Linux) osn=linux;; Darwin) osn=darwin;; *) emit node fail "unsupported OS: $os"; exit 1;; esac
        arch=$(uname -m); case "$arch" in x86_64|amd64) a=x64;; aarch64|arm64) a=arm64;; *) emit node fail "unsupported arch: $arch"; exit 1;; esac
        # macOS takes the .tar.gz release: bsdtar is not guaranteed to read xz, while
        # the gzip tarball always works. Linux keeps the smaller .tar.xz.
        case "$osn" in darwin) ext=tar.gz; flag=z;; *) ext=tar.xz; flag=J;; esac
        dir="$HOME/.dsh/runtime"; mkdir -p "$dir" || { emit node fail "cannot create $dir"; exit 1; }
        sums="$dir/SHASUMS256.txt"
        if command -v curl >/dev/null 2>&1; then
          curl -fsSL "https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt" -o "$sums" 2>/dev/null
        else
          wget -qO "$sums" "https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt" 2>/dev/null
        fi
        file=$(grep -o "node-v[0-9.]*-$osn-$a.$ext" "$sums" 2>/dev/null | head -1)
        [ -n "$file" ] || { emit node fail "cannot resolve Node release"; exit 1; }
        url="https://nodejs.org/dist/latest-v24.x/$file"
        if command -v curl >/dev/null 2>&1; then
          curl -fsSL "$url" -o "$dir/node.$ext" 2>/dev/null
        else
          wget -qO "$dir/node.$ext" "$url" 2>/dev/null
        fi
        top=$(basename "$file" ".$ext")
        tar -x"$flag"f "$dir/node.$ext" -C "$dir" 2>/dev/null || tar -xf "$dir/node.$ext" -C "$dir" 2>/dev/null
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
    """#

    /// PowerShell: verify Node 24.9+, install @deepseek-ai/dsh, verify. Node itself is
    /// not installed here (the Windows launcher leaves that to the user, see Plan).
    static let windows = #"""
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
    """#
}
