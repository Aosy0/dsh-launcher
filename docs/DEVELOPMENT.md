# 開発メモ（DSH Launcher）

`AGENTS.md` の詳細版。実装・変更・障害対応のときに読む。

## 構成

```
dsh-launcher/
├─ AGENTS.md                 # セッション引き継ぎ（最小）
├─ README.md                 # 使い方・現状・インストール手順
├─ DESIGN.md                 # 設計・デザイン・決定事項
├─ docs/DEVELOPMENT.md       # このファイル
├─ .github/workflows/release.yml  # v* タグ → ビルドして GitHub Release を作成
├─ install.ps1               # 配布用インストーラ（latest を取得・検証・配置）
├─ tools/make-icon.py        # app.ico の生成（Pillow が必要）
├─ src/DshLauncher/
│  ├─ DshLauncher.csproj     # net9.0-windows / UseWPF / UseWindowsForms / <Version> / ApplicationIcon
│  ├─ app.ico                # アプリアイコン（make-icon.py で生成。直接編集しない）
│  ├─ Program.cs             # WinExe。引数あり→CLI、無し/gui→WPF。ConsoleBridge
│  ├─ AppInfo                # バージョン文字列（アセンブリ由来）
│  ├─ Model.cs               # hosts.json、MachineStatus、ポート検出（netstat）
│  ├─ Local.cs               # ローカル起動/停止/状態（タスクスケジューラ起動）
│  ├─ Remote.cs              # SSH、リモート検出/操作、agent.sh / agent.ps1
│  ├─ BrowserApp.cs          # ブラウザの Web アプリ（PWA）検出・起動（app id 算出、プロファイル走査）
│  ├─ PwaAuth.cs             # PWA の初回認証（署名クッキー発行・ブラウザ設定・認証状態）
│  ├─ Setup.cs               # RemoteSetup/SetupScripts（Node+dsh 導入）、Ps1Encoding(BOM)
│  ├─ Cli.cs                 # dshl サブコマンド、MachineOps
│  ├─ Ui.cs                  # 一覧ウィンドウ・トレイ・テーマ・LoadingBar
│  └─ Dialogs.cs             # 確認/名前変更/マシン追加/ログ（すべてコピー可能）
├─ design/                   # v1/v2/v3 のモックと実機キャプチャ
└─ dist/dshl.exe             # publish 成果物（リポジトリ内での実行用）
```

## ビルドと配布

```powershell
cd src/DshLauncher
dotnet build -c Debug
dotnet publish -c Release -r win-x64 --self-contained false `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
  -o C:\Users\koboy\Documents\dsh-launcher\dist
```

- publish 前に `Get-Process dshl | Stop-Process -Force`（実行中だと `MSB4018` で失敗）
- `dist\dshl.exe` は framework-dependent 単一 exe（約 0.5MB。アイコン込み）。.NET 9 Desktop Runtime が必要
- 起動: `dist\dshl.exe`。CLI: 同じ exe に `dshl status|start|stop|restart|setup|rename|machines|logs|url|open|pwa|--version`
- アイコンは `python tools/make-icon.py` で `src/DshLauncher/app.ico` を再生成する（Pillow が必要。ico はコミットする）

## リリース（GitHub Releases）

配布物は GitHub Actions が作る。**タグと csproj の `<Version>` は一致させる**（ワークフローが検証して失敗する）。

1. `src/DshLauncher/DshLauncher.csproj` の `<Version>` を上げる（例 `0.1.10`）
2. ビルドして `dist\dshl.exe` を更新し、README / このファイルを更新
3. コミットして push: `git add -A; git commit -m "v0.1.10"; git push origin main`
4. タグを作って push: `git tag v0.1.10; git push origin v0.1.10`
5. Actions が自動で実行される:
   - 自己完結の単一 exe `dshl-<ver>-win-x64.exe`（約 70MB、.NET 不要）
   - framework-dependent `dshl-<ver>-win-x64-framework-dependent.exe`（約 0.5MB）
   - `install.ps1` と `SHA256SUMS.txt`
   を添付した Release を作成（`gh release create --generate-notes`）
   インストール先には `install.ps1` / `update.cmd` / `uninstall.cmd` が置かれ、実行ポリシーに関係なく更新・削除できる
7. Release 本文の先頭には `.github/release-header.md`（非公式の断り書き＋インストール1行）が自動で前置される
   （workflow の「Prepend unofficial-tool header」）
6. 確認: `gh run list --workflow release.yml` / `gh release view v0.1.10` /
   インストール動作は `.\install.ps1 -Version v0.1.10 -InstallDir $env:TEMP\dshl-test -NoShortcut` で確認できる

- リポジトリの Actions は public リポジトリで自動実行される。手動実行は無し（タグのみ）
- 署名はしていないため、初回実行時に SmartScreen の警告が出る（README に案内あり）

## 実行時データ（秘密情報なし）

| 種類 | 場所 |
|---|---|
| 設定 | `%APPDATA%\DshLauncher\hosts.json`（camelCase。`machines[]`） |
| PWA 認証の記憶 | `%APPDATA%\DshLauncher\pwa-auth.json`（ブラウザ・プロファイル・authority・有効期限。秘密情報なし） |
| PWA 認証の secret | `$DSH_HOME/.credentials.yaml` の `client-connection/browser-session`（DSH が管理。ランチャーは読むだけで変更しない） |
| ローカル起動ログ | `%APPDATA%\DshLauncher\logs\<id>.log` |
| リモートセットアップログ | `%APPDATA%\DshLauncher\logs\<id>-setup.log` |
| ローカル起動スクリプト | `%APPDATA%\DshLauncher\run\<id>.cmd` / `<id>.vbs` |
| リモートヘルパー(Linux) | `~/.dsh/dshl/agent.sh`（+ `setup.sh`） |
| リモートヘルパー(Windows) | `%USERPROFILE%\.dsh\dshl\agent.ps1`（+ `setup.ps1`） |
| Windows リモートの起動物 | `%USERPROFILE%\.dsh\dshl\run-<port>.cmd/.vbs`、`dsh-<port>.log` |
| タスクスケジューラ | `DshLauncher\start-<id>`（ローカル）/ `DshLauncher\remote-<port>`（Windows リモート） |

## 設計上の重要な決定（壊すと再発する）

1. **起動は Task Scheduler 経由 + wscript 非表示**
   - アプリから子プロセスとして起動すると、CLI をパイプで使ったとき親が待ち続ける／SSH セッション終了で子が死ぬ。
   - ローカル: `run-<id>.cmd`（User スコープの OPENCODE_* キーを registry から読む）を `run-<id>.vbs` が隠して起動。
   - Windows リモート: agent.ps1 が `run-<port>.cmd/.vbs` を書き、`schtasks /Create /IT` → `/Run`。
   - 停止時はポート占有プロセスのツリー kill → タスク削除 → 残った cmd ラッパー削除。
2. **プロファイルは位置引数**: `dsh <profile> --port <port> --no-open`。
3. **ポート検出は netstat**（管理者不要）。`Get-NetTCPConnection` はリモートの PowerShell で使用。
4. **SSH 検出は PATH を自分で構築**: nvm / `~/.dsh/runtime/node` / `~/.dsh/npm-global` を前置してから
   `node -v` / `command -v dsh` を実行（非対話 SSH は nvm を読まない）。
5. **Windows .ps1 は UTF-8 BOM**: 5.1 が BOM なしを CP932 として読むため、日本語入りだと構文破壊。
6. **`$Profile` 禁止**: PowerShell の自動変数。`$ProfileName` を使う。
7. **`Get-Command dsh` より `%APPDATA%\npm\dsh.cmd`**: 環境によって `.ps1` シムが返り cmd.exe で動かない。
8. **UI は再描画を抑制**: 操作中に `RebuildList()` を呼ぶと LoadingBar の Storyboard がリセットされ、
   「左から出たバーが途中で消える」ように見える。`UpdateBusyLabels()` のみ呼ぶ。
9. **ダイアログ**: ウィンドウ全体の `DragMove()` はマウスをキャプチャしてボタンを飲む。
   非インタラクティブ領域だけドラッグ。ボタンは必ず実 `Button`（ControlTemplate 付き）。
10. **バージョン**: `<Version>` を上げる。UI 右下と `dshl --version` はアセンブリから取得。
11. **PWA を開くはマシン非依存**（`BrowserApp.cs`）:
    - 配置はボトムバー右の主ボタンとトレイ最上位。行メニュー・マシン別サブメニューには出さない
      （Web アプリは 1 オリジン＝このPCの DSH に属し、マシン行の操作ではない）。
    - 対象は Chromium 系（Chrome / Edge / Brave / Chromium。Brave は Beta/Dev/Nightly も）。
      ユーザー向け文言は特定ブラウザ名を出さず「ブラウザ」に統一する。
    - app id = `GenerateId(SHA256(manifest id))` = **二重 SHA-256**（先頭16バイトを a–p へ）。
      DSH の manifest は `start_url: "./"` なので manifest id は URL のディレクトリ（既定 `http://host:port/`）。
    - 判定は各ブラウザの `<User Data>\<Profile>\Web Applications\_crx_<id>`（Edge は `_crx__<id>`）/
      `Manifest Resources\<id>` の実フォルダのみ。`.lnk` 解析・ブラウザ内部 DB は使わない（壊れやすい）。
    - 起動はブラウザ同梱の proxy（`chrome_proxy.exe` / `msedge_proxy.exe`）に
      `--profile-directory="Profile N" --app-id=<id>`。無ければブラウザ exe。
    - ローカル DSH は `127.0.0.1` / `localhost` の両表記を試す。
    - 検出結果は `dshl pwa --json`（`browser` / `browsers`） / `dshl pwa --dry-run` で確認できる。
12. **PWA の初回認証はクッキー再生成で自動化**（`PwaAuth.cs`）:
    - DSH の Web UI は `dsh-auth-<authority の SHA-256>` という署名つき HttpOnly クッキーで保護される
      （`@deepseek-ai/dsh-client-connection` の browser-session）。dsh web の起動時ログ（`?token=` 付き URL）は
      **dsh 実行中に排他ロックされていて読めない**ため、ログからトークンを取る方式は使えない。
    - 代わりに `$DSH_HOME/.credentials.yaml` の `client-connection/browser-session` secret から
      **同じ形式のクッキーを生成**し、サーバーへ Cookie ヘッダで 200 を確認してから、
      `127.0.0.1` の一時 HTTP サーバー（`Set-Cookie` + DSH へ 302）を**非表示のアプリウィンドウ**で開いて設定する。
      クッキーはポート非依存なので `127.0.0.1:<ephemeral>` から `127.0.0.1:3080` に有効。
    - ペイロードは `{"version":1,"authority","issuedAt","expiresAt"}`、`v1.<b64url(body)>.<b64url(HMAC-SHA256(secret, body))>`。
      `expiresAt - issuedAt` はプロファイルの `cookieMaxAgeDays`（既定 30、最大 400 日相当に丸め）以下にする。
    - 認証済み判定は、PWA ウィンドウタイトル（401 は authority、認証済みはアプリ名）と
      `%APPDATA%\DshLauncher\pwa-auth.json` の両方。401 のときだけ認証を更新して開き直す。
    - 自動認証は `http://127.0.0.1:<port>` の PWA のみ（https のオリジンにはクッキーを設定できない）。
    　手動検証は `dshl pwa --json`（`authenticated` / `authAvailable`）、`dshl pwa --open`。

## テスト手順（本番 3080 を触らない）

1. テスト設定を作る（別 DSH_HOME・別ポート）:
   `%TEMP%\dshl-test-hosts.json`
   ```json
   {"version":1,"machines":[{"id":"lab","kind":"local","name":"lab","profile":"labweb","port":3090,
     "environment":{"DSH_HOME":"C:\\Users\\koboy\\.dsh-oc-lab"}}]}
   ```
2. `dshl.exe gui --config <そのパス>` で起動
3. CLI: `dshl start lab --config <path> --json` → `status` → `stop`
4. UI 自動操作（UIAutomation）でボタンを押す検証が可能:
   - `AutomationElement` を ProcessId で取得し、`ControlType.Button` + `Name` で検索 → `InvokePattern`
   - ダイアログはオーナー付きのため root 直下に出ない。`EnumWindows` + `GetWindowText` でハンドルを探す
5. ウィンドウ画像は `PrintWindow(hwnd, hdc, 2)` で取得（画面キャプチャより確実）
6. PWA の検出・起動・認証:
   - `dshl pwa` が `DeepSeek Harness  <appId>  Profile N  <url>` と実行行を出す
   - `dshl pwa --json` で `browser`（起動に使うブラウザ）・`browsers`（検出したブラウザ一覧）・
     `authenticated`（認証状態）・`authAvailable`（自動認証の可否）を確認できる
   - `dshl pwa --dry-run` が `<browser proxy> --profile-directory=... --app-id=...` を返す
   - GUI のボトムバー「PWA を開く」を `InvokePattern` で押すと既存のアプリウィンドウへフォーカス
     （重複ウィンドウは作られない）。未インストールなら案内ダイアログ
   - 初回認証（401）の検証は、クッキーを消した別ブラウザプロファイルで行うのが安全。手順:
     `~/.dsh/.credentials.yaml` の secret からクッキーを計算 → `127.0.0.1` の一時 HTTP ページで
     `Set-Cookie` → `brave.exe --user-data-dir=<temp> --app=http://127.0.0.1:<ephemeral>/` を開き、
     タイトルがアプリ名になれば成功（Cookie DB にも `dsh-auth-*` が残る）

## トラブルシュート

| 症状 | 対処 |
|---|---|
| CLI 出力が file リダイレクトで空 | WinExe+AttachConsole の制約。パイプ（`\| Out-String`）で受ける |
| publish が `MSB4018` | 実行中の dshl が exe をロック。停止してから publish |
| 起動が「timeout waiting for port」 | ログ確認（`logs\<id>.log` / リモートの `dsh*.log`）。プロファイル名・dsh パス・BOM を疑う |
| リモートで「dsh が見つかりません」 | PATH 構築（nvm/ポータブル）と `.cmd` 優先を確認。`agent.sh/ps1` を再配置 |
| セットアップ失敗 | `logs\<id>-setup.log` を確認。Node 24.9+ / npm 到達性 / BOM |
| タスクが Running のまま残る | 旧ビルド（cmd 直接起動）の残り。停止/再起動で掃除される |
| 「PWA が見つかりません」 | `dshl pwa --json` で `browser` / `browsers` / appId / profile を確認。各ブラウザのプロファイル（例 Chrome: `%LOCALAPPDATA%\Google\Chrome\User Data\Profile N\Web Applications\_crx_<id>`、Edge は `_crx__<id>`）に実フォルダがあるか。ローカル DSH の URL（host/port）がインストール時と一致しているか |
| 「認証を更新しましたが、PWA が認証状態になりません」 | `dshl pwa --json` の `authAvailable` と `%APPDATA%\DshLauncher\pwa-auth.json` を確認。`$DSH_HOME/.credentials.yaml` に `client-connection/browser-session` があるか、PWA を `http://127.0.0.1:<port>` からインストールしたか（https オリジンは自動認証の対象外）。DSH 再起動後に再試行 |

## 既知の未対応

- URL（Tailscale）の設定 UI（今は `hosts.json` の `url` を直接編集）
- 9台以上での絞り込み欄の表示テスト（実装済みだが未検証）
- GUI からのリモートセットアップ実行の実機確認（CLI では検証済み）
- アプリ終了時にトレイを残すか終了するかの設定

