import Foundation

/// Remote helper scripts. Deployment copies these to `~/.dsh/dshl/` over SSH; they are
/// a few kilobytes and audit-able, and nothing else is ever installed on a remote host.
///
/// They are raw string literals on purpose: no Swift interpolation runs over shell or
/// PowerShell text, so editing a script cannot accidentally splice in a value.
enum AgentScripts {
    /// POSIX sh helper for Linux and macOS (`status|start|stop|restart`).
    ///
    /// macOS differences from the Windows launcher's helper:
    /// - `setsid` is not installed, so start falls back to plain `nohup` (SIGHUP is
    ///   ignored, and the dsh server survives the SSH session closing).
    /// - a background job there is not a process-group leader, so stop never kills
    ///   `-PID`: it walks children with `pgrep` and asks `lsof` for the port listener.
    /// - port detection tries `ss`, then `netstat` (macOS prints `127.0.0.1.3080` with a
    ///   dot, not a colon), then `lsof`; Homebrew's `/opt/homebrew/bin` is on the PATH.
    static let posix = #"""
    #!/bin/sh
    # dshl remote agent: manage one dsh web service. Verbs: status|start|stop|restart
    # Linux and macOS. Deliberately small: everything here is revocable by deleting
    # ~/.dsh/dshl, and the launcher installs nothing else on the host.
    DIR="$HOME/.dsh/dshl"
    PORT="${DSH_PORT:-3080}"
    PROFILE="${DSH_PROFILE:-web}"
    PIDF="$DIR/dsh.pid"
    LOG="$DIR/dsh.log"
    add_paths() {
      PATH="$HOME/.dsh/npm-global/bin:$HOME/.dsh/runtime/node/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
      for p in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$p" ] && PATH="$p:$PATH"; done
      export PATH
    }
    add_paths
    find_dsh() {
      for c in dsh "$HOME/.dsh/npm-global/bin/dsh" "$HOME/.npm-global/bin/dsh" "$HOME/.local/bin/dsh" "$HOME/.dsh/runtime/node/bin/dsh" /opt/homebrew/bin/dsh /usr/local/bin/dsh; do
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
      if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | grep -q "[:.]$PORT " && return 0
      fi
      if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | grep -q "[:.]$PORT " && return 0
      fi
      if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && return 0
      fi
      return 1
    }
    listener_pids() {
      if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null
      elif command -v ss >/dev/null 2>&1; then
        ss -ltnp 2>/dev/null | grep "[:.]$PORT " | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p'
      else
        pgrep -f "dsh .*--port $PORT" 2>/dev/null
      fi
      return 0
    }
    kill_tree() {
      _sig="$1"
      _pid="$2"
      [ -n "$_pid" ] || return 0
      for _child in $(pgrep -P "$_pid" 2>/dev/null); do
        kill_tree "$_sig" "$_child"
      done
      kill -s "$_sig" "$_pid" 2>/dev/null
      return 0
    }
    looks_like_dsh() {
      _pid="$1"
      [ -n "$_pid" ] || return 1
      if listener_pids 2>/dev/null | grep -qx "$_pid"; then return 0; fi
      ps -p "$_pid" -o command= 2>/dev/null | grep -q "dsh"
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
      p=$!
      printf '%s\n' "$p" > "$PIDF"
      i=0
      while [ "$i" -lt 90 ]; do
        if port_open; then printf '{"state":"running","pid":%s,"port":%s}\n' "$p" "$PORT"; return 0; fi
        sleep 1
        i=$((i+1))
      done
      printf '{"state":"error","reason":"timeout waiting for port %s"}\n' "$PORT"
      return 1
    }
    do_stop() {
      # The Windows helper treats whatever listens on the port as the service, and this
      # follows that rule; the pidfile process is only signalled after a name check so a
      # recycled PID cannot take an unrelated process down with it.
      for _p in $(listener_pids 2>/dev/null); do
        kill_tree TERM "$_p"
      done
      if _p=$(running_pid); then
        if looks_like_dsh "$_p"; then kill_tree TERM "$_p"; fi
      fi
      _i=0
      while [ "$_i" -lt 10 ]; do
        port_open || break
        sleep 1
        _i=$((_i+1))
      done
      if port_open; then
        for _p in $(listener_pids 2>/dev/null); do
          kill_tree KILL "$_p"
        done
        if _p=$(running_pid); then
          if looks_like_dsh "$_p"; then kill_tree KILL "$_p"; fi
        fi
        _i=0
        while [ "$_i" -lt 5 ]; do
          port_open || break
          sleep 1
          _i=$((_i+1))
        done
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
    """#

    /// PowerShell 5.1 helper for remote Windows hosts, deployed as `agent.ps1` with a
    /// UTF-8 BOM (without it 5.1 reads the file as ANSI). Kept verbatim from the Windows
    /// launcher: dsh has to be started through `wscript` + Task Scheduler so that the
    /// SSH session ending cannot take the server down.
    static let windows = #"""
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
    """#
}

/// Byte-level helpers shared by helper deployment and the setup scripts.
enum ScriptEncoding {
    /// UTF-8 with a BOM: Windows PowerShell 5.1 needs it to parse non-ASCII `.ps1` text.
    static func utf8BOM(_ text: String) -> Data {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: text.utf8)
        return data
    }

    /// Base64 of the BOM-prefixed UTF-8 text, for `[Convert]::FromBase64String()`.
    static func base64UTF8BOM(_ text: String) -> String {
        utf8BOM(text).base64EncodedString()
    }

    /// `powershell -EncodedCommand` takes base64 of UTF-16LE. Writing scripts this way
    /// keeps quoting out of the SSH command line (the Windows launcher does the same).
    static func encodedCommand(_ script: String) -> String {
        let data = script.data(using: .utf16LittleEndian) ?? Data()
        return data.base64EncodedString()
    }

    /// POSIX single-quote escaping for a value pasted into a remote sh command.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// PowerShell single-quote escaping (a literal quote doubles inside `'...'`).
    static func powerShellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
