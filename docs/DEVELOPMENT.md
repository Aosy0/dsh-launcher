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
│  ├─ AuthUrl.cs             # 新しいブラウザの認証 URL（起動ログの ?token= をクッキー発行で検証して発行）
│  ├─ Update.cs               # アプリ内更新（Releases 確認・SHA256 検証・exe 差し替え・再起動）
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
macOS 版も同じ `<Version>` を `mac/build.sh` が読む（個別のバージョン番号は持たない）。
現状の `release.yml` は Windows 版だけをビルドする。Mac の配布物は Mac で
`cd mac && ./build.sh` を実行して `DSHLauncher-<ver>-mac-<arch>.zip` を作り、必要なら手動で Release に添付する。

1. `src/DshLauncher/DshLauncher.csproj` の `<Version>` を上げる（例 `0.1.10`）
2. ビルドして `dist\dshl.exe` を更新し、必要なら Mac でも `mac/build.sh` を実行して zip を作る。
   README / このファイルを更新
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
| 更新用の一時ファイル | `%TEMP%\dshl-update-*`（ダウンロードした exe と置き換え用ヘルパー .ps1。適用後にヘルパーが移動・削除） |
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
      （`@deepseek-ai/dsh-client-connection` の browser-session）。通常は dsh web の起動時ログ（`?token=` 付き URL）
      を開いて取得するが、PWA の自動認証は「401 を待ってから URL を開き直す」ことを避けるため、このログには依存しない
      （ログは `>>` 追記なので実行中も読める。URL が要る用途は 14 の `AuthUrl.cs`）。
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

13. **アプリ内更新は exe を直接差し替える**（Update.cs）:
    - 確認は GitHub Releases の eleases/latest（起動6秒後と6時間ごと + 手動）。
    - 実行中の exe と同じ種類のアセット（自己完結 / framework-dependent）を選び、SHA256SUMS.txt と照合する。
      自己完結かどうかは exe サイズ > 20MB で判定。
    - 適用は**非表示の PowerShell ヘルパー**（UTF-8 BOM）が「プロセス終了待ち（最大60秒）→ Move-Item →
      Start-Process」を行う。アプリはヘルパー起動後に終了する。インストーラは呼ばない（ポータブル配置でも更新できる）。
    - 事前条件: 更新先に書き込めること、同じ exe の別インスタンスが無いこと。満たさなければ理由を返す。
    - 更新確認の失敗はサイレント（手動確認時のみダイアログ）。UI はステータスバーのリンクとトレイのバルーン/メニュー。
14. **新しいブラウザの認証 URL は起動ログ + クッキー発行の確認**（`AuthUrl.cs`）:
    - dsh web の launch token はプロセスごとの乱数で、永続化されない。起動時に
      `dsh web: <url>?token=...` として 1 回だけ stdout に出る（`printUrl` 既定 true）。
    - ランチャーの起動スクリプトは `>>` 追記なので、実行中も `FileShare.ReadWrite` でログを読める。
      末尾 256 KB から `dsh web: <url>` を新しい順に最大 6 件拾う。
    - 再起動前のトークンもログに残るため、**必ず実行中サーバーへ `http://127.0.0.1:<port>/?token=…` を投げて
      3xx + `Set-Cookie: dsh-auth-…` を確認**する（古いトークンは 401）。これを省くと再起動後に古い URL を配ってしまう。
    - 検証クライアントは **Cookie を保持しない**（`UseCookies = false`）。サーバーは有効な Cookie 付きの
      リクエストも 303 で通すため、保持すると再起動前の古いトークンを有効と誤認する。
    - トークンは authority に依存しない。主 URL は `hosts.json` の `url` → ログの非ループバック URL →
      `http://127.0.0.1:<port>/` の順で決め、ループバック版も併記する。
    - トークンはファイルへ保存しない。UI/CLI の出力が唯一の配布経路（ダイアログにも注意書き）。
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

7. アプリ内更新の検証（リリースを汚さない）:
   - dotnet publish ... -p:Version=0.1.0 -o %TEMP%\dshl-update-test で**古いバージョン番号のコピー**を作る
   - dshl.exe update --check --json で available: true と選ばれる asset を確認
   - dshl.exe update でダウンロード → SHA256 検証 → 差し替え → 再起動（--version が最新になる）を確認
   - GUI はコピーを起動し、6秒後にステータスバー/トレイに通知が出ることを確認。リンクを押すと確認ダイアログ → 更新 → 再起動
   - 検証後は %TEMP%\dshl-update-test のプロセスを止めて削除する
8. 新しいブラウザの認証 URL:
   - `dshl auth-url --json` が `ok` / `url` / `localUrl` / `externalUrl` / `token` / `pid` / `message` を返す（稼働中のローカル DSH）
   - `dshl auth-url` の stdout は URL 1 行（パイプで受ける）。`--copy` / `--open` は副作用あり
   - 失敗系の見分け: 停止中 →「DSH が停止しています」、ログに起動行なし →「取得できません」、
     古いトークンだけ（別プロセスのログを使う等）→「古くなっています」
   - 古いトークンの検証は、`logs\<別id>.log` に過去の `dsh web:` 行がある状態で、その id のローカル設定を
     稼働中ポートに向けると 401 判定を再現できる
   - GUI はボトムバー「認証 URL」を `InvokePattern` で押し、ダイアログの URL・コピー・「ブラウザで開く」を確認
     （ダイアログは `PrintWindow(hwnd, hdc, 2)` で撮る）
9. 認証 URL の実効性: 返った URL を Cookie の無いブラウザプロファイルで開き、DSH の画面（401 でない）に
   なることを確認する。同じ URL を再び開いても 303 で通る（トークンは使い捨てではない）。
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
| 「認証 URL」を発行できない | `dshl auth-url --json` の `message` を確認。停止中なら起動する。ログ（`logs\<id>.log`）に `dsh web: …?token=…` があるか（`printUrl: false` だと出ない）、ランチャー経由で起動したか。再起動前の古い URL は 401 になる（`AuthUrl.cs` は 3xx + `Set-Cookie: dsh-auth-…` で検証して選ぶ） |

| 更新が「別の DSH Launcher が起動中」で止まる | 他のランチャー（トレイ常駐）を終了してから再実行。同一 exe がロックされている |
| 更新後に起動しない | %TEMP%\dshl-update-* の状態を確認。exe が差し替わっていれば手動起動で復帰可能。ウイルス対策が exe をロックしていないか確認 |
## 既知の未対応

- URL（Tailscale）の設定 UI（今は `hosts.json` の `url` を直接編集）
- リモートマシンの認証 URL 発行（今はローカル DSH のみ。リモートは `dsh.log` の取得と、SSH 経由の応答確認が要る）
- 9台以上での絞り込み欄の表示テスト（実装済みだが未検証）
- GUI からのリモートセットアップ実行の実機確認（CLI では検証済み）
- アプリ終了時にトレイを残すか終了するかの設定

## macOS 版（mac/）

Windows 版と同じ機能を SwiftUI + AppKit で実装したもの。設計は [DESIGN.md](../DESIGN.md)
「13. macOS 版」、使い方は [README.md](../README.md) の macOS の節。

### ビルドと配置

```sh
# Mac 実機（ssh macbook、Apple M1 / macOS 27.0.1 / Xcode 27.2）
cd mac
./build.sh              # dist/DSH Launcher.app / dist/dshl / dist/DSHLauncher-<version>-mac-<arch>.zip
./install.sh            # ~/Applications と ~/.local/bin/dshl に配置
./uninstall.sh [--purge]
```

- Windows からは `scp -r mac macbook:~/dsh-launcher/` で同期し、バージョンのために
  `src/DshLauncher/DshLauncher.csproj` も置いてから
  `cd ~/dsh-launcher/mac && ./build.sh` を実行する:
  ```sh
  ssh macbook 'mkdir -p ~/dsh-launcher/src/DshLauncher'
  scp src/DshLauncher/DshLauncher.csproj macbook:~/dsh-launcher/src/DshLauncher/
  ```
  `mac/.build/` と `mac/dist/` は git 管理外。
- Swift のビルドは Mac 実機で行う（Windows に Swift ツールチェーンはない）。
- アイコンは `mac/Support/AppIcon-1024.png`（Windows 版 `app.ico` と同じ意図）から
  `sips` + `iconutil` で生成。`app.ico` を変えたら `python tools/make-mac-icon.py` で
  PNG も作り直す（Pillow が必要。PNG はコミットする）。
- 署名は ad-hoc のみ（`codesign --force --sign -`）。公証はしない。
- バージョンは Windows 版と同じ。`mac/build.sh` が `src/DshLauncher/DshLauncher.csproj` の
  `<Version>` を読んで Info.plist（`CFBundleShortVersionString` / `CFBundleVersion`）に書き込み、
  `dshl --version` はバンドルの値を表示する。`VERSION=... ./build.sh` で上書きもできるが、
  通常は csproj だけを更新する。

### 構成

| ファイル | 役割 |
|---|---|
| `Entry` 相当（`main.swift`） | GUI / CLI 分岐。GUI は**同期トップレベル**から `MainActor.assumeIsolated` で開始 |
| `App.swift` | NSStatusItem（メニューバー）・NSWindow・メインメニュー |
| `AppState.swift` | 5秒ポーリング、操作、シート状態、集計 |
| `Model.swift` | Machine / hosts.json / 状態 / Paths |
| `CLI.swift` | `dshl` サブコマンド + 開発用 `snapshot` |
| `LocalMachine.swift` | LaunchAgent の生成・bootstrap/kickstart・停止・ログ |
| `RemoteMachine.swift` | SSH プローブ、ヘルパー配置、操作、ログ |
| `AgentScripts.swift` | `agent.sh` / `agent.ps1`（raw string） |
| `RemoteSetup.swift` | Node 24.9+ / dsh のセットアップ |
| `DshResolver.swift` | nvm / npm-global / Homebrew / ポータブル Node の解決 |
| `AuthURL.swift` | `dsh web:` ログの token 検証と URL 発行 |
| `BrowserApp.swift` | `~/Applications/*.localized` の Web アプリ検出・起動 |
| `UI/` | Theme / Components / MainView / Dialogs |

### 落とし穴（再発しやすい）

1. **`NSApplication.run()` を MainActor タスク内で呼ばない**
   - `@main` の async main から `MainActor.run { AppMain.run() }` すると、MainActor タスクが
     戻らず、`AppState.startPolling()` の `Task` が永久に実行されない（UI は出るが状態が
     更新されない）。`main.swift` の同期トップレベルから `MainActor.assumeIsolated` で開始する。
2. **`NSApplication.delegate` は弱参照**
   - `AppMain.retainedDelegate` で強参照する。保持しないと起動後に AppDelegate が解放される。
3. **launchd は GUI アプリの PATH を継承しない**
   - 起動スクリプトで `PATH` を明示し、nvm / `~/.npm-global/bin` / `/opt/homebrew/bin` /
     `~/.dsh/runtime/node` から Node 24.9+ と dsh を解決する。`RunAtLoad` は無効。
4. **macOS の `netstat -ltn` は `127.0.0.1.3080`（ドット区切り）**
   - ポート判定は `[:.]$PORT` でマッチし、`ss` が無い環境では `lsof` も使う。
5. **`setsid` / `ss` / `stat -c` / `timeout` は macOS に無い**
   - リモート `agent.sh` は nohup + pgrep/lsof で停止。検証コマンドで `timeout` を使わない。
6. **SSH からの `screencapture` は TCC で失敗**
   - UI 検証は `logs/app.log`・`lsappinfo`・HTTP 401/303・`dshl snapshot` で行う。
7. **token は起動ログに平文で残る**
   - `~/Library/Application Support/DshLauncher/logs/<id>.log` は 0600、フォルダは 0700。
     共有時は `?token=` を伏せる。
8. **PWA 検出は Windows と別方式**
   - Windows の `Web Applications\_crx_<id>` は macOS には無い。`~/Applications/<ブランド>
     Apps.localized/*.app/Contents/Info.plist` の `CrAppModeShortcutID` / `URL` を読む。
     app id は manifest id の二重 SHA-256 → a–p（`http://127.0.0.1:3080/` は
     `hgiemfgfjhalibdoboikeiepnnjapnpc`）。

### テスト手順（本番 3080 を触らない）

```sh
# ラボ: 別 DSH_HOME・別ポート
mkdir -p ~/.dsh-lab/profiles && cp -R ~/.dsh/profiles/web ~/.dsh-lab/profiles/labweb
cat > /tmp/dshl-lab.json <<'EOF'
{"version":1,"machines":[{"id":"lab","kind":"Local","name":"lab","sshAlias":null,
 "platform":"auto","profile":"labweb","port":3090,"url":null,"pinned":true,
 "environment":{"DSH_HOME":"/Users/<you>/.dsh-lab"}}]}
EOF
dshl start lab --config /tmp/dshl-lab.json --json
dshl status lab --config /tmp/dshl-lab.json --json   # 稼働中 / PID
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3090/   # 401
dshl auth-url --config /tmp/dshl-lab.json --json      # ok + token
dshl restart lab --config /tmp/dshl-lab.json --json   # PID が変わる
dshl stop lab --config /tmp/dshl-lab.json --json      # ポートが閉じ、plist が消える
```

- リモート: `ssh minipc`（Linux）と `ssh cps`（Windows）が Mac から通る。
  `dshl status` / `logs` / `setup` / `start` / `stop` を確認済み。minipc の HTTP は
  SSH 越しに `curl http://127.0.0.1:3080/` で 401。
- PWA 検出: `~/Applications/Chrome Apps.localized/<name>.app/Contents/Info.plist` に
  `CrAppModeShortcutID` / `CrAppModeShortcutURL` を持つ偽アプリを作り、
  `dshl pwa --json` が検出することを確認（確認後は削除）。
- UI: `dshl snapshot /tmp/ui.png` でオフスクリーン描画。`design/mac-v1.png` はこの出力。
  実画面の確認は人手（SSH からは TCC で不可）。

### 配布

- 現状は Mac 実機でビルドした `.app` / zip を `~/Applications` に置く運用。
- GitHub Releases へ載せる場合は、Windows の `release.yml` とは別に macOS ランナーで
  `mac/build.sh` を実行し、`DSHLauncher-mac-<arch>.zip` を添付する（未対応。必要になったら追加）。
- 署名・公証は未対応。配布時は README の Gatekeeper 手順を添える。



