# DSH Launcher

DeepSeek Harness（`dsh`）を、この PC とリモートマシンで起動・再起動・停止・状態確認するための
デスクトップアプリ＋ CLI（`dshl`）。Windows 版は WPF / .NET 9、macOS 版は SwiftUI / AppKit で、
**同じバージョン（v0.1.16）と同じ CLI 語彙**を提供します。プラットフォームごとの違いはこの
README 内に併記しています。

> 非公式のサードパーティ製ランチャーです。DeepSeek 公式の製品ではなく、DeepSeek による承認・提携・サポートはありません。
> 「DeepSeek Harness」は DeepSeek の登録商標で、本プロジェクトでは互換性の説明にのみ使用しています。
> 詳細は [ライセンスと非公式について](#ライセンスと非公式について)。

![Windows UI](design/v3/24-gui-pwa.png)

![macOS UI](design/mac-v1.png)

## ドキュメント

| 内容 | 場所 |
|---|---|
| セッション引き継ぎ（エージェント向け） | [AGENTS.md](AGENTS.md) |
| 設計・デザイン・決定事項 | [DESIGN.md](DESIGN.md) |
| 開発・ビルド・テスト・障害対応 | [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) |

## プラットフォームの違い

| | Windows | macOS |
|---|---|---|
| UI | 一覧ウィンドウ＋トレイ常駐（WPF） | 一覧ウィンドウ＋メニューバー常駐（SwiftUI + AppKit） |
| ローカル起動 | タスクスケジューラ＋`wscript` の非表示起動 | ユーザー LaunchAgent（`RunAtLoad` 無効＋`kickstart`） |
| リモート操作 | SSH＋`agent.sh` / `agent.ps1` | 同左（`agent.sh` は macOS の `nohup` / `lsof` 対応） |
| PWA 検出 | 各ブラウザの `Web Applications\_crx_<id>` | `~/Applications/*.localized/*.app` の Info.plist |
| PWA 初回認証 | 署名クッキーを自動生成して設定 | 未対応（認証 URL で対応） |
| 認証 URL | 起動ログの `?token=` を検証して発行 | 同左（起動直後は最大 10 秒待つ） |
| アプリ内更新 | あり（GitHub Releases） | なし（ビルドし直し） |
| 配布 | 自己完結 exe / `install.ps1` | `.app` zip / `install.sh`（ad-hoc 署名） |
| CLI | `dshl.exe`（GUI と同一） | `dshl`（`.app` 内バイナリのラッパー） |

## インストール

### Windows

Windows 10/11（x64）。Releases の exe は単体で動く（.NET ランタイム不要、自己完結版）。

```powershell
irm https://github.com/Aosy0/dsh-launcher/releases/latest/download/install.ps1 | iex
```

- `%LOCALAPPDATA%\Programs\DshLauncher\dshl.exe` に配置し、スタートメニューに「DSH Launcher」を追加する
- 配布物の SHA256 を `SHA256SUMS.txt` と照合してから配置する
- 更新: 同じコマンドを再実行、または `& "$env:LOCALAPPDATA\Programs\DshLauncher\update.cmd"`
- アンインストール（設定・ログも消すなら `-Purge`）:
  ```powershell
  & "$env:LOCALAPPDATA\Programs\DshLauncher\uninstall.cmd"
  ```

ポータブル（インストールしない）:

- [Releases](https://github.com/Aosy0/dsh-launcher/releases) から `dshl-<version>-win-x64.exe` をダウンロードして
  実行するだけ（約 70MB、.NET 不要）。
- .NET 9 Desktop Runtime が入っている場合は軽量版 `dshl-<version>-win-x64-framework-dependent.exe`（約 0.5MB）も使える。
- 未署名の exe のため、初回は SmartScreen の「Windows によって PC が保護されました」が出ることがある。
  「詳細情報」→「実行」で進む。

### macOS

macOS 13 以降。Xcode Command Line Tools（`swift` / `sips` / `iconutil` / `codesign`）が必要です。

```sh
cd mac
./build.sh          # dist/DSH Launcher.app / dist/dshl / dist/DSHLauncher-<version>-mac-<arch>.zip
./install.sh        # ~/Applications/DSH Launcher.app と ~/.local/bin/dshl
```

- アプリは `~/Applications`、CLI は `~/.local/bin` に置く。`/Applications` も sudo も使わない。
- `~/.local/bin` が PATH に無い場合は `~/.zshrc` に追加:
  ```sh
  export PATH="$HOME/.local/bin:$PATH"
  ```
- アンインストール: `./uninstall.sh`（設定・ログも消すなら `--purge`）。
- 未署名（ad-hoc 署名のみ）なので、ダウンロードした zip を展開した場合は Gatekeeper の警告が出ることがある。
  Finder で右クリック →「開く」、または:
  ```sh
  xattr -dr com.apple.quarantine "$HOME/Applications/DSH Launcher.app"
  ```
- 開発中は `open "dist/DSH Launcher.app"` で直接起動してもよい。

### 前提

| 使う機能 | Windows | macOS |
|---|---|---|
| この PC の DSH を起動 / 停止 | Node.js 24.9 以上と `dsh`（`npm i -g @deepseek-ai/dsh`） | 同左 |
| リモートの DSH を操作 | `~/.ssh/config` のホストエイリアス（鍵認証） | 同左 |
| PWA を開く | Chromium 系ブラウザ（Chrome / Edge / Brave など）で DSH を「アプリとしてインストール」したもの | 同左（Chrome / Brave / Vivaldi / Edge） |
| ビルド | .NET 9 SDK（配布版のビルド時） | Xcode Command Line Tools |

## はじめかた

1. 起動するとマシン一覧のウィンドウと常駐（Windows: トレイ / macOS: メニューバー）が始まる。
   初回に `hosts.json` を作成し、`~/.ssh/config` のホストを一覧へ自動で追加する。
2. この PC の行の「起動」で DSH を起動する。Windows はタスクスケジューラ、macOS は LaunchAgent を
   経由するので、ランチャーを閉じても残る。
3. リモートが「要セットアップ」なら「DSH をセットアップ」で Node と dsh を導入する。
4. 「PWA を開く」で、DSH をインストール済みブラウザの Web アプリとして開ける。
   Windows は初回（未認証）に自動で認証を更新してから開く。未インストールならブラウザで開いて
   追加する手順を案内する。
5. コマンドラインは同じバイナリ:

   ```powershell
   # Windows
   & "$env:LOCALAPPDATA\Programs\DshLauncher\dshl.exe" status --json
   ```

   ```sh
   # macOS
   ~/.local/bin/dshl status --json
   ```

## 共通の機能と仕組み

### マシン一覧と操作

- 状態でグループ化（稼働中 / 要対応 / 停止）。選択行だけが URL・PID・稼働時間・メモリ・
  実行コマンド（受領書）をインライン展開する。
- 起動・再起動・停止は、実行前に対象・現在状態・**実行するコマンド**を見せる確認ダイアログを出す。
- マシンの追加・名前変更・削除（ローカル行は削除不可）、ログ表示、集計表示。
- Windows はトレイ、macOS はメニューバーから同じ操作ができる。

### ローカル起動

どちらも `dsh <profile> --port <port> --no-open` を、ランチャーのプロセスツリーから切り離して起動する。

**Windows**: タスクスケジューラ（`DshLauncher\start-<id>`）＋`wscript` の非表示ランチャー。
起動スクリプトは `run-<id>.cmd` / `run-<id>.vbs`。停止時はポート占有プロセスのツリーを終了し、
タスクとラッパーを掃除する。

**macOS**: ユーザー LaunchAgent
（`~/Library/LaunchAgents/io.github.aosy0.dshlauncher.start-<id>.plist`）。`RunAtLoad` と
`KeepAlive` は無効で、`launchctl bootstrap` → `kickstart -k` のときだけ起動する。停止は
`bootout` のあと、ポート占有プロセスの子孫を終了して plist を削除する。GUI アプリと launchd は
シェルの PATH を継承しないため、起動スクリプトが nvm / `~/.npm-global/bin` / Homebrew /
`~/.dsh/runtime/node` から Node 24.9+ と dsh を解決して PATH を明示する。ログ
（`?token=` を含む）は 0600、アプリのデータフォルダは 0700。

### リモート

`~/.ssh/config` の Host エイリアスをそのまま使う。認証は鍵 / ssh-agent のみで、パスワードは保存しない
（`BatchMode=yes`、`ConnectTimeout=5`）。

- 状態検出は SSH 1 回。`uname -s` / `node -v` / `command -v dsh` / `~/.dsh` / ポートの LISTEN /
  ヘルパーの `status` をまとめて取得する。Linux / macOS は POSIX、Windows は PowerShell で判定。
- 操作は `~/.dsh/dshl/agent.sh`（POSIX）/ `agent.ps1`（Windows）。`dshl setup <machine>` で配置し、
  `--install` を付けると Node 24.9+ と dsh も導入する。自動では配置しない。
- macOS のリモートでは `setsid` が無いため `nohup` で起動し、停止は pidfile と `lsof` / `pgrep` で
  子孫を終了する。Windows リモートは UTF-8 BOM 付きの `agent.ps1` をタスクスケジューラ＋`wscript` で動かす。

### 認証 URL

dsh web は起動時に一度だけ `dsh web: <url>?token=...` を出力する。ランチャーは起動ログ（末尾 256 KB）
から候補を拾い、**稼働中のサーバーが 3xx + `Set-Cookie: dsh-auth-…` を返すものだけ**を採用する。
古いトークンは 401 で捨てる（検証クライアントは Cookie を保持せず、リダイレクトも追わない）。

- 対象は**ランチャー経由で起動したローカル DSH** のみ。リモートは未対応。
- トークンは認証情報そのもの。ランチャーはファイルに保存せず、画面・クリップボード・CLI の
  stdout / JSON に出すだけ。dsh を再起動すると URL は変わる。
- Windows は 2.5 秒、macOS は 10 秒の猶予で起動直後のログ行を待つ。

### PWA（Web アプリ）を開く

**Windows**: Chromium 系ブラウザの `<User Data>\<Profile>\Web Applications\_crx_<id>`
（Edge は `_crx__<id>`）で検出し、`chrome_proxy.exe` / `msedge_proxy.exe` に
`--profile-directory` と `--app-id` を渡して起動する。初回認証（401）は
`$DSH_HOME/.credentials.yaml` の browser-session secret から署名クッキーを再生成し、
非表示のアプリウィンドウ＋一時ローカルページで設定してから開き直す。

**macOS**: Chromium 系ブラウザが `~/Applications/Chrome Apps.localized` などに作る `.app` の
`Contents/Info.plist`（`CrAppModeShortcutID` / `CrAppModeShortcutURL`）を読み、`open -a` で起動する。
ブラウザ内部 DB は読まない。**初回認証のクッキー自動生成は未実装**で、認証 URL をブラウザで開いて
認証する。

どちらも app id は manifest id の**二重 SHA-256**（先頭 16 バイトを a–p に写像）。DSH の manifest は
`start_url: "./"` なので、`http://127.0.0.1:3080/` の app id は
`hgiemfgfjhalibdoboikeiepnnjapnpc`。未インストール時はインストールせず、ブラウザで開いて案内する。

### データの場所

| 種類 | Windows | macOS |
|---|---|---|
| 設定 | `%APPDATA%\DshLauncher\hosts.json` | `~/Library/Application Support/DshLauncher/hosts.json` |
| 起動ログ | `%APPDATA%\DshLauncher\logs\<id>.log` | `~/Library/Application Support/DshLauncher/logs/<id>.log` |
| アプリログ | — | `~/Library/Application Support/DshLauncher/logs/app.log` |
| 起動スクリプト | `%APPDATA%\DshLauncher\run\<id>.cmd` / `.vbs` | `~/Library/Application Support/DshLauncher/run/<id>.sh` |
| スケジューラ | タスク `DshLauncher\start-<id>` | LaunchAgent `io.github.aosy0.dshlauncher.start-<id>.plist` |
| PWA 認証の記憶 | `%APPDATA%\DshLauncher\pwa-auth.json` | なし |
| リモートヘルパー | `~/.dsh/dshl/agent.ps1` | `~/.dsh/dshl/agent.sh` |

### バージョン

`src/DshLauncher/DshLauncher.csproj` の `<Version>` が**唯一の情報源**です（現在 `0.1.16`）。

- Windows: UI 右下と `dshl --version` がアセンブリのバージョンを表示する。
- macOS: `mac/build.sh` が csproj の `<Version>` を読み、`CFBundleShortVersionString` /
  `CFBundleVersion` に設定する。`dshl --version` はバンドルの値を表示する。
- リリースのタグ `vX.Y.Z` は `<Version>` と一致させる（Windows の Release ワークフローが検証する）。
  macOS 版も同じ番号を使う。個別のバージョン番号は持たない。

## CLI

```sh
dshl status [machine] [--all] [--json]
dshl start|stop|restart [machine] [--yes] [--dry-run] [--json]
dshl machines [--json]
dshl url [machine]
dshl logs [machine] [-n 50]
dshl setup [machine] [--install] [--dry-run]   # ヘルパー配置 / Node と dsh の導入
dshl rename <machine> <name>
dshl add <name> <ssh-alias> [linux|windows|macos]
dshl remove <machine>
dshl open [machine] [--dry-run]
dshl pwa [--open] [--dry-run] [--json]
dshl auth-url [machine] [--copy] [--open] [--json]
dshl gui
dshl --version
```

- Windows のみ: `dshl update [--check] [--dry-run] [--json]`（アプリ内更新）。
- macOS の開発用: `dshl snapshot <out.png>`（一覧をオフスクリーン描画。SSH から `screencapture` が
  使えない環境の確認用。ユーザー向け機能ではない）。
- `--config <path>` で別の `hosts.json` を使える（ラボ検証用）。
- 終了コード: `0` 成功 / `1` エラー / `2` 変更なし / `3` 到達不可 / `4` 要セットアップ。

## 実装状況（v0.1.16 / 2026-11-13）

| 機能 | Windows | macOS |
|---|---|---|
| 一覧ウィンドウ（状態グループ・選択行の展開・集計） | ✅ 実装 | ✅ 実装 |
| ローカル: 起動 / 再起動 / 停止 / 状態（PID・稼働時間・メモリ） | ✅ 実機確認 | ✅ 実機確認（launchd） |
| ローカルの表示名 `マシン名(local)` | ✅ `nzxt(local)` | ✅ `MacBoooook Air!(local)` |
| マシン名の編集（右クリック → 名前を変更…、`dshl rename`） | ✅ 実装 | ✅ 実装 |
| 常駐（集計・マシン別サブメニュー・終了） | ✅ トレイ | ✅ メニューバー |
| 確認ダイアログ（対象・実行コマンド・現在状態） | ✅ 実装 | ✅ 実装 |
| リモート: SSH 検出（OS / Node / dsh / ~/.dsh / ポート / 遅延） | ✅ 実機確認 | ✅ 実機確認 |
| リモート: ヘルパー自動配置（`setup`） | ✅ 実機確認 | ✅ 実機確認（minipc / cps） |
| リモート: 起動 / 再起動 / 停止 | ✅ 実機確認 | ✅ 実機確認（Linux / Windows） |
| リモート: DSH の自動セットアップ（Node 24.9+ と dsh） | ✅ 実機確認 | ✅ 実装（dry-run まで確認） |
| ログ表示（ローカルはファイル、リモートは tail） | ✅ 実装 | ✅ 実装 |
| マシン追加（SSH エイリアス・ポート・プロファイル） | ✅ 実装 | ✅ 実装 |
| PWA を開く（Web アプリ検出・起動） | ✅ 実機確認（初回認証も自動） | ✅ 検出・起動（初回認証の自動化は未対応） |
| 新しいブラウザの認証 URL（`?token=` 付き）の発行 | ✅ 実機確認 | ✅ 実機確認 |
| アプリ内更新（通知 → ダウンロード → 置き換え → 再起動） | ✅ 実装・実機確認 | — |
| 配布（Release / インストーラ / アイコン） | ✅ v0.1.10 から | ✅ .app / zip / `install.sh` |
| URL の編集 UI / フィルタ表示（9台以上） | ⏳ 次段 | ⏳ 次段 |

## 開発とビルド

| | Windows | macOS |
|---|---|---|
| ビルド | `dotnet publish`（[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)） | `cd mac && ./build.sh` |
| 実行 | `dist\dshl.exe` | `open "mac/dist/DSH Launcher.app"` / `~/.local/bin/dshl` |
| テスト | 別 DSH_HOME・別ポートのラボ | 同左（`~/.dsh-lab`・port 3090） |

- Windows のビルド・リリース手順、テスト手順、トラブルシュート: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
- macOS の構成・launchd の落とし穴・リモート検証・スナップショット: 同じ
  [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) の「macOS 版」。
- バージョンを上げるときは `src/DshLauncher/DshLauncher.csproj` の `<Version>` を更新する
  （Windows / macOS 共通）。

## 構成

```
dsh-launcher/
├─ .github/workflows/release.yml  # v* タグ → Windows 版をビルドして GitHub Release を作成
├─ install.ps1            # Windows 配布用インストーラ（latest を取得・検証・配置）
├─ tools/make-icon.py     # app.ico の生成（Pillow が必要）
├─ tools/make-mac-icon.py # macOS 用 AppIcon-1024.png の生成
├─ DESIGN.md              # 監査・方向・9パス・リモート設計・CLI仕様・決定事項
├─ design/                # v1/v2/v3 のモック、mac-v1.png（macOS 実機の描画）
├─ mockups/v0/            # 最初の3案（比較用）
├─ src/DshLauncher/       # Windows 版 WPF (.NET 9) 実装
│  ├─ Program.cs          # GUI/CLI 分岐（WinExe + コンソール接続）
│  ├─ Model.cs            # 設定・状態・ポート検出
│  ├─ Local.cs            # ローカル起動/停止/状態（タスクスケジューラ起動）
│  ├─ Remote.cs           # SSH・リモート検出/操作・ヘルパースクリプト
│  ├─ BrowserApp.cs       # PWA の検出と起動（app id 算出・プロファイル走査）
│  ├─ PwaAuth.cs          # PWA の初回認証（署名クッキー発行・ブラウザ設定）
│  ├─ AuthUrl.cs          # 新しいブラウザの認証 URL
│  ├─ Update.cs           # アプリ内更新
│  ├─ Cli.cs              # dshl サブコマンド
│  ├─ Ui.cs / Dialogs.cs  # 一覧・トレイ・確認ダイアログ
│  └─ app.ico
├─ mac/                   # macOS 版（SwiftUI + AppKit + CLI）
│  ├─ build.sh            # csproj の <Version> を読んで .app / dshl / zip を生成
│  ├─ install.sh          # ~/Applications と ~/.local/bin に配置
│  ├─ uninstall.sh
│  ├─ Package.swift
│  ├─ Support/            # Info.plist と AppIcon-1024.png
│  └─ Sources/DshLauncherMac/  # launchd・SSH・認証URL・PWA・UI・CLI
└─ dist/dshl.exe          # ビルド済み Windows 単一ファイル（.NET 9 Desktop Runtime 使用）
```

## 修正履歴

macOS 版は v0.1.16 が初版です。以下はプラットフォームごとの履歴です。

### macOS 版 v0.1.16（初版 / 2026-11-13）

- `mac/` に SwiftUI + AppKit のメニューバーアプリと CLI を追加。Windows 版と同じバージョン 0.1.16。
- 一覧・状態グループ・選択行の受領書・起動/再起動/停止・ログ・マシン追加/名前変更/削除。
- ローカル起動は LaunchAgent（`RunAtLoad` 無効 + `kickstart`）。`Umask` 077 でログを 0600 に。
- リモートは SSH プローブ＋`agent.sh` / `agent.ps1`。macOS の `setsid` 不在・`netstat` のドット表記に
  対応した停止処理。
- 認証 URL（起動ログの token を 3xx + `Set-Cookie` で検証、10 秒猶予）、PWA 検出
  （`~/Applications/*.localized` の Info.plist、二重 SHA-256 の app id）。
- `dshl snapshot`（開発用のオフスクリーン描画）、`build.sh` / `install.sh` / `uninstall.sh`。
- 実機（Apple M1 / macOS 27.0.1）で、ローカル 3080 の launchd 起動/停止/再起動、minipc（Linux）/
  cps（Windows）の検出・起動/停止、認証 URL、PWA 検出を確認。
- **未対応**: アプリ内更新、PWA 初回認証の自動化、リモートの認証 URL、公証（ad-hoc 署名のみ）。

### Windows 版

#### v0.1.16

- **新しいブラウザの認証 URL を発行**。dsh web が起動時に 1 回だけ出力する `?token=` 付き URL を、
  ボトムバー「認証 URL」・ローカル行メニュー・トレイ・`dshl auth-url` から発行できるようにした。
  - 取得元はランチャーが起動した dsh のログ（`%APPDATA%\DshLauncher\logs\<id>.log`）。
    `dsh web: …?token=…` を新しい順に拾い、稼働中のサーバーが **3xx + `Set-Cookie: dsh-auth-…` を返す
    ものだけ**を採用する（再起動前の古いトークンは 401 で捨てる。検証クライアントは Cookie を保持しない）
  - ダイアログに公開 URL（Tailscale など）と「この PC のブラウザ用」（`127.0.0.1`）を並べ、
    コピーと「ブラウザで開く」を用意。PID と注意書きも表示する
  - CLI: `dshl auth-url [machine] [--copy] [--open] [--json]`（stdout は URL 1 行）
  - PWA 自動認証の説明にあった「起動ログは排他ロックで読めない」を実測に合わせて訂正
  - `docs/DEVELOPMENT.md` の制御文字（BEL）を修正

#### v0.1.15

- **アプリ内更新を追加**。起動後と6時間ごとに GitHub Releases を確認し、新しければ
  ステータスバーに「v0.1.15 に更新」、トレイに通知（バルーン）を出す。クリックすると
  **ブラウザを開かずに**ダウンロード → SHA-256 検証 → 置き換え → 新しいバージョンで再起動まで行う。
  - ダウンロードするのは実行中の exe と同じ種類（自己完結 / framework-dependent。exe サイズで判定）
  - 置き換えは非表示の PowerShell ヘルパーが「本体の終了待ち → exe 差し替え → 起動」を行う
  - 更新先に書き込めない場合・別のランチャーが起動中の場合は実行せず理由を表示
  - トレイメニューに「更新を確認…」「v0.1.15 に更新…」、CLI に `dshl update [--check] [--dry-run] [--json]`

#### v0.1.14

- **PWA の初回認証を自動化**。「PWA を開く」で未認証（401 画面）を検知すると、
  DSH が発行するブラウザセッションクッキーを自動で発行してブラウザプロファイルに設定し、PWA を開き直す。
  - dsh web は署名つき HttpOnly クッキー（`dsh-auth-*`）で UI を保護する。通常は起動時に表示される
    `?token=` 付き URL を開いて取得するが、PWA の自動認証では**その URL を開き直さない**。
    `$DSH_HOME/.credentials.yaml` の browser-session secret から**同じクッキーを再生成**し、
    ランチャーの一時ローカルページ（`http://127.0.0.1:<ephemeral>/`、クッキーはポート非依存）経由で
    ブラウザに設定する。設定先は**非表示のアプリウィンドウ**なので、タブやウィンドウは残らず、
    ワンタイムの URL も履歴に残らない。
  - 認証済みかどうかは、PWA のウィンドウタイトル（401 は `127.0.0.1:3080`、認証済みはアプリ名）と
    `%APPDATA%\DshLauncher\pwa-auth.json`（ブラウザ・プロファイル・有効期限）で判断する。
  - 自動認証は `http://127.0.0.1:<port>` からインストールした PWA が対象（クッキーを設定できるループバック限定）。
    `dshl pwa --open` でも同じ自動認証が働く。

- 「Brave」前提だった表記を**「ブラウザ」に統一**し、PWA（Web アプリ）を
  **Chrome / Edge / Brave / Chromium** から自動検出して起動できるようにした。
  - 検出は各ブラウザの `<User Data>\<Profile>\Web Applications\_crx_<id>`（Edge は `_crx__<id>`）。
    起動はブラウザ同梱の `chrome_proxy.exe` / `msedge_proxy.exe` に `--profile-directory` と `--app-id` を渡す。
  - Firefox など Web アプリをインストールできないブラウザは対象外（UI 上は特定ブラウザ名を出さない）。
  - 未インストール時の案内: 「ブラウザで開く」で既定のブラウザに URL を開く。
- ボトムバーの「PWA を開く」ボタンの**内側の余白が狭い**問題を修正。ボタンのテンプレートが `Padding` を
  使っておらず、幅の広いラベル（PWA を開く / セットアップ / ブラウザで開く）で文字が端に寄っていた。
  テンプレートに左右 14px の余白を追加し、高さも他の主ボタンと同じ 28px に揃えた。
- CLI: `dshl pwa --json` に `browser`（起動に使うブラウザ）と `browsers`（検出したブラウザ一覧）を追加。

#### v0.1.12

- アプリアイコンを `>_` のプロンプト記号から **DSH の文字マーク**へ変更（ターミナルエミュレーターに見えるため）。
  各サイズは `design/icon-sizes.png`。
- インストール先に `update.cmd` / `uninstall.cmd` を追加。Windows の既定の実行ポリシー（Restricted）でも
  更新・アンインストールができる（`powershell -ExecutionPolicy Bypass` 経由の .cmd）。
  配置先の `install.ps1` は Windows PowerShell 5.1 でも読めるよう **UTF-8 BOM 付き**で書き出す。
  アンインストールは、実行中の .cmd が消えて cmd.exe がエラーを出さないよう**終了後にバックグラウンドで削除**する。

#### v0.1.11

- `install.ps1` の修正: 配置先にコピーされたインストーラから `-Uninstall` を実行したとき、
  `-InstallDir` を指定してインストールしていても**元の配置先**（dshl.exe と同じフォルダ）を既定にする。
  インストール先の削除はロックが外れるまで数回リトライする。

#### v0.1.10

- **他のPCへ配布できるようにした**。
  - 自己完結の単一 exe（.NET ランタイム不要、約 70MB）と framework-dependent（約 0.5MB、.NET 9 Desktop Runtime が必要）を
    GitHub Releases に添付。`.github/workflows/release.yml` が `v*` タグの push でビルドして Release を作成する
    （タグと csproj の `<Version>` が一致しないと失敗）。
  - `install.ps1`: latest の exe を取得 → `SHA256SUMS.txt` と照合 → `%LOCALAPPDATA%\Programs\DshLauncher` に配置 →
    スタートメニューにショートカット。`-Uninstall` / `-Purge`。自分自身も配置先にコピーするので更新・削除に再取得は不要。
  - アプリアイコン（`src/DshLauncher/app.ico`、`python tools/make-icon.py` で生成）を追加し、
    ウィンドウ・トレイ・ショートカットを同じ意匠に。exe のメタデータ（ProductName / Description）も設定。

#### v0.1.9

- PWA を開く導線を**マシンから独立**させ、ボトムバー右の主ボタンと**トレイの最上位**に置いた。名前は「**PWA を開く**」。
  行メニュー・選択行の展開・トレイのマシン別サブメニューからは外した（PWA はこのPCの DSH に属するもので、マシン行の操作ではないため）。
- CLI: `dshl pwa [--open] [--dry-run] [--json]` に整理（情報表示 / 起動 / 実行コマンド表示 / JSON）。
  v0.1.8 の `dshl open <machine> --app` と `dshl apps` は削除。
- 検出と起動の仕組みは v0.1.8 のまま（`chrome_proxy.exe --profile-directory="Profile N" --app-id=<id>`）。

#### v0.1.8

- ローカル DSH の PWA（ブラウザの Web アプリ）検出と起動を追加
  （v0.1.9 で導線をマシン非依存に、v0.1.13 で Chromium 系ブラウザ一般に拡張）。
  - Brave の Web アプリは `chrome_proxy.exe --profile-directory="Profile N" --app-id=<id>` で起動する
    （Start Menu の `Brave Apps` ショートカットと同じ行）。
  - app id は **Web App Manifest の id を二重 SHA-256** した Chromium の a–p 記法。DSH は manifest に `id` が無く
    `start_url: "./"` なので、manifest id は URL のディレクトリ（既定はオリジン直下）。
    実測: `http://127.0.0.1:3080/` → `hgiemfgfjhalibdoboikeiepnnjapnpc`（存在の判定は
    `Web Applications\_crx_<id>` と `Manifest Resources\<id>`）。
  - PWA が未インストールなら案内ダイアログを出し、「Brave で開く」で URL をタブで開く。
  - SSH マシンは `url` 未設定だと `http://127.0.0.1:<port>/` に解決され、この PC の PWA と一致してしまうため対象外。
  - 起動は既存のブラウザ起動と同じく子プロセスを残さない（`UseShellExecute`。DSH 本体の起動だけがタスクスケジューラ経由）。

#### v0.1.7

- 起動/再起動中のインジケータバーが「左から出て途中で消える」問題を修正。
  600ms ごとの一覧再描画でバーを作り直していたのが原因。操作中は**経過秒数のテキストだけ更新**し、
  バーのアニメーションを維持するようにした（再描画は操作完了時のみ）。リモート起動でも同様。

#### v0.1.6

- 右下のバージョン表記を固定文字列 0.1 から**アセンブリのバージョン**（csproj の `<Version>`）表示に変更。
- CLI に `dshl --version`（および `dshl version`）を追加。
- 今後バージョンを上げるときは `src/DshLauncher/DshLauncher.csproj` の `<Version>` を更新して再ビルド。
  macOS 版も同じ `<Version>` を `mac/build.sh` が読む（v0.1.16 から）。

#### v0.1.5

- Windows リモートのセットアップ失敗を修正:
  - `.ps1` を **UTF-8 BOM 付き**で配置（BOM なしだと Windows PowerShell 5.1 が CP932 として読み、日本語入りスクリプトが構文エラーになる）。
  - Windows 側ヘルパーのパラメータ `$Profile` が PowerShell の**自動変数**と衝突していたため `$ProfileName` に改名。
  - `Get-Command dsh` が `.ps1` シムを返し `cmd.exe` から実行できなかったため、`%APPDATA%\npm\dsh.cmd` を優先。
  - SSH セッション終了で子プロセスが落ちるため、Windows リモートも **タスクスケジューラ + wscript 非表示起動**に統一。
- 例外メッセージを**コピー可能**に: ダイアログに「コピー」ボタン、本文・受領書は選択可能、ログ窓に「すべてコピー」。
- 実測: cpswhitegtx1080ti で Node v26.13.0 / dsh 0.2.2-rc.1 を導入 → 起動（HTTP 401）→ 停止（タスク・ポート掃除）まで確認。

#### v0.1.4

- リモートマシンへの **DSH セットアップ** を追加。`dshl setup <machine> --install`、GUI は「要セットアップ」行のボタン／右クリック →「DSH をセットアップ…」。
  - Linux: nvm があれば `nvm install 24`、無ければポータブル Node 24 を `~/.dsh/runtime/node` に導入 → `npm i -g @deepseek-ai/dsh@latest` → ヘルパー配置。
  - Windows: Node 24.9+ を確認 → `npm i -g @deepseek-ai/dsh@latest` → ヘルパー配置。
  - 実行結果は画面のログ窓と `%APPDATA%\DshLauncher\logs\<id>-setup.log` に残る。
- リモートのヘルパーが nvm / ポータブル Node の PATH を自分で解決するように修正（非対話 SSH で dsh が見つからない問題）。
- リモート起動コマンドの誤り（`web --profile` 二重指定）を修正。

#### その他（v0.1.1〜v0.1.3）

- v0.1.1: ダイアログのボタンが反応しない問題を修正（ウィンドウ全体の `DragMove()` がマウスを掴んでいた）。
  キャンセルで閉じない問題も解消。受領書のコマンド表記を `dsh <profile> --port <port> --no-open` に短縮。
- v0.1.2: 起動/再起動/停止中の進行表示（経過秒数・インジケータバー）を追加。タスクスケジューラの
  アクションを `wscript.exe` 経由の非表示ランチャーに変更。
- v0.1.3: 行内の「再起動 / 停止 / 起動」ボタンの余白を拡大（高さ 28px・左右 14px・最小幅 64px）。

## ライセンスと非公式について

- **ライセンス**: [MIT](LICENSE)（Copyright (c) 2026 Aosy）。商用利用・改変・再配布可、無保証。
- **非公式**: 本プロジェクトはサードパーティ製で、DeepSeek 公式ではありません。DeepSeek による承認・提携・サポートはありません。
- **名称**: 上流の [ブランドガイドライン](https://github.com/deepseek-ai/deepseek-harness/blob/master/BRAND_GUIDELINES.md) に従い、
  プロジェクト名には略称 **DSH** を使用し、フルネーム「DeepSeek Harness」は互換性の説明にのみ使用します。
  「DeepSeek Harness」は DeepSeek の登録商標です。公式ロゴ・ブランド素材は使用していません（アイコンは本プロジェクトの自作）。
- **上流**: DeepSeek Harness（`dsh`）は [MIT](https://github.com/deepseek-ai/deepseek-harness/blob/master/LICENSE) で公開されています。
  本ランチャーは `dsh` のコードを同梱・改変せず、CLI の起動と Web UI / PWA を開くだけです。
- **開発者プレビュー**: DSH は developer preview で互換性が壊れる変更があります。本ランチャーの追従・動作は保証しません。

## 実測メモ

| ホスト | OS | Node | dsh | 状態 |
|---|---|---|---|---|
| このPC（nzxt(local)） | Windows | v24.18.0 | 0.2.2-rc.1 | 稼働中 |
| minipc-server | Linux | v24.13.0 | 0.2.2-rc.1 | 稼働中（検出・起動/停止を実機確認） |
| cpswhitegtx1080ti | Windows | v26.13.0 | 0.2.2-rc.1 | 稼働中（検出・起動/停止を実機確認） |
| macbook（MacBoooook Air!） | macOS 27.0.1 | v24.16.0 | 0.2.2-rc.1 | 稼働中（macOS 版・launchd 管理で実機確認） |
