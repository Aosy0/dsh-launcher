# DSH Launcher — エージェント引き継ぎ

dsh（DeepSeek Harness）のランチャー。Windows 版は WPF/.NET 9 アプリと CLI が同一 exe、
macOS 版は SwiftUI + AppKit のメニューバーアプリと CLI（`mac/`）。作業ディレクトリはこのフォルダ。
応対は日本語で行う。

## 必ず守ること

- **バージョン**: `<Version>` の更新と `dist\dshl.exe` の更新は**リリースを指示されたときだけ**
  行う（画面右下と `dshl --version` はアセンブリ由来）。通常の不具合修正ではバージョンを上げない。
  macOS 版も同じ `<Version>` を `mac/build.sh` が読む（個別のバージョン番号は持たない）。
- **push**: 自分から push しない。通常の修正はコミットまでで止め、push はユーザーが明示的に
  push / リリースを指示したときだけ行う。
- **リリース**: ユーザーが明示的にリリースを指示したときだけ行う。配布物は GitHub Actions
  （`.github/workflows/release.yml`）が `v*` タグ push で作る。タグ `vX.Y.Z` は csproj の
  `<Version>` と一致させる（不一致はワークフローが失敗）。手順は docs/DEVELOPMENT.md「リリース」。
  タグ push と GitHub Release は DSH の push ガードで確認されるため、指示のない限り実行しない。
  アイコンは `src/DshLauncher/app.ico`（`python tools/make-icon.py` で生成、直接編集しない）。
- **名称とライセンス**: 本プロジェクトは **MIT**。非公式ツールであることを README と Release 本文に明記する。
  プロジェクト名は「DSH」、フルネーム「DeepSeek Harness」は互換性の説明にのみ使う
  （上流 https://github.com/deepseek-ai/deepseek-harness/blob/master/BRAND_GUIDELINES.md に従う）。
- **置き換え前**: 実行中の `dshl` は `dist\dshl.exe` をロックする。プロセスを停止してから publish。
- **dsh の起動方式**: タスクスケジューラ＋`wscript` の非表示ランチャーを維持する。
  アプリや SSH から `dsh web` を直接起動すると、CLI のパイプ待ちや SSH セッション終了で落ちる。
- **ローカル起動コマンド**: `dsh <profile> --port <port> --no-open`。
  `dsh web --profile web` は「プロファイル二重指定」で失敗する。
- **リモート Windows**: `.ps1` は UTF-8 BOM 付きで配置。`$Profile` は PowerShell の自動変数なので使わない
  （`$ProfileName`）。dsh は `%APPDATA%\npm\dsh.cmd` を優先（`.ps1` シムは cmd.exe で実行不可）。
- **UI**: 操作中（起動/再起動/停止/セットアップ）は一覧を再描画せず、経過テキストだけ更新する。
  再描画するとインジケータバーのアニメーションがリセットされる。
- **PWA を開く（ブラウザの Web アプリ）**: **マシン非依存**。ボトムバー右とトレイ最上位に置き、CLI は `dshl pwa --open`。
  対象は Chromium 系（Chrome / Edge / Brave / Chromium、Brave は Beta/Dev/Nightly も）。検出は各ブラウザの
  `<User Data>\<Profile>\Web Applications\_crx_<id>`（Edge は `_crx__<id>`）、起動はブラウザ同梱の proxy
  （`chrome_proxy.exe` / `msedge_proxy.exe`）に `--profile-directory` `--app-id`。app id は manifest id の
  **二重 SHA-256**。`.lnk` 解析・ブラウザ内部 DB は使わない。検出は `dshl pwa --json`（`browser` / `browsers`）。
  **ユーザー向け文言は特定ブラウザ名を出さず「ブラウザ」に統一**する。
- **PWA の初回認証**: 401 を検知したら `PwaAuth.cs` が `$DSH_HOME/.credentials.yaml` の browser-session secret から
  署名クッキー（`dsh-auth-*`）を生成し、非表示のアプリウィンドウ＋一時ローカルページでブラウザに設定して開き直す。
  認証状態は `%APPDATA%\DshLauncher\pwa-auth.json` とウィンドウタイトルで判断する。対象は `127.0.0.1` の PWA のみ。
- **新しいブラウザの認証 URL**: `AuthUrl.cs`。起動ログ（`%APPDATA%\DshLauncher\logs\<id>.log`、`>>` 追記で
  実行中も読める）の `dsh web: …?token=…` を新しい順に拾い、稼働中のサーバーが **3xx（`Set-Cookie: dsh-auth-…`
  付き）を返すものだけ**を発行する（再起動前の古い行は 401 で捨てる）。検証クライアントは Cookie を保持しない
  （保持すると古いトークンでも 303 になる）。トークンは保存しない。UI はボトムバー「認証 URL」・
  ローカル行メニュー・トレイ、CLI は `dshl auth-url [--copy] [--open] [--json]`。リモートは未対応。
- **アプリ内更新**: `Update.cs`。`releases/latest` を確認し、実行中の exe と同じ種類のアセットを
  SHA256 検証してから、非表示 PowerShell ヘルパーで exe を差し替えて再起動する（インストーラは呼ばない）。
  UI はステータスバーの「v<ver> に更新」とトレイ通知、CLI は `dshl update [--check]`。
  更新先に書き込めない/別インスタンスが起動中なら実行しない。

## macOS 版（mac/）

- 実装は **SwiftUI + AppKit のメニューバーアプリ + CLI（同一バイナリ）**。Windows 版とコードは共有しない。
  設計は [DESIGN.md](DESIGN.md) の「13. macOS 版」、使い方は [README.md](README.md)（プラットフォーム別の節）。
- **ビルド・実機検証は Mac**（`ssh macbook`、Apple M1 / macOS 27.0.1 / Xcode 27.2）で行う。
  Windows の `mac/` と `src/DshLauncher/DshLauncher.csproj`（バージョンの情報源）を scp して
  `~/dsh-launcher/mac` で `./build.sh`。`mac/.build/` と `mac/dist/` は
  git 管理外（zip は配布時に Release 添付）。
- ローカル起動は **ユーザー LaunchAgent**
  （`~/Library/LaunchAgents/io.github.aosy0.dshlauncher.start-<id>.plist`）で、
  `RunAtLoad` 無効 + `launchctl bootstrap` → `kickstart -k`。停止は `bootout` → ポート占有 PID の
  子孫を終了 → plist 削除。Windows の Task Scheduler + wscript に相当する。
  **`dsh web` を直接バックグラウンド起動しない**（SSH セッション終了で落ちる）。
- 起動ログは `~/Library/Application Support/DshLauncher/logs/<id>.log`。認証 URL はこのログの
  `dsh web:` 行だけを根拠にし、**3xx + `Set-Cookie: dsh-auth-…`** で検証する。検証クライアントは
  Cookie を保持せずリダイレクトも追わない（古いトークンの誤判定を防ぐ）。トークンは保存しない。
- PWA は `~/Applications` の `Chrome Apps.localized` などの `.app` の Info.plist
  （`CrAppModeShortcutID` / `CrAppModeShortcutURL`）で検出して `open -a`。ブラウザ内部 DB は読まない。
  PWA の初回認証（Cookie 再生成）は未実装。
- Mac 版のバージョンは **Windows 版と同じ**。`mac/build.sh` が
  `src/DshLauncher/DshLauncher.csproj` の `<Version>` を読み、Info.plist と `dshl --version` に反映する。
  個別のバージョン番号は持たない。**リリース指示があるまで上げない**。
- Mac 実機の GUI 検証は、SSH からの `screencapture` が TCC で失敗するため、`logs/app.log`・
  プロセスの存在・HTTP 401/303・`lsappinfo` で行う。画面確認は人手。
- Mac 上の dsh は `~/.npm-global/bin/dsh`（nvm の Node 24.16.0 を直接呼ぶラッパー）。
  ローカル 3080 はランチャー（launchd）管理。検証用ラボは `--config /tmp/dshl-lab.json` と
  `~/.dsh-lab`（port 3090 / profile labweb）を使い、本番 3080 を触らない。

## 詳細ドキュメント

| 内容 | 場所 |
|---|---|
| 使い方・現状・実測 | [README.md](README.md) |
| macOS 版の使い方・ビルド | [README.md](README.md)（macOS の節） |
| 設計・決定事項・デザイン | [DESIGN.md](DESIGN.md) |
| 開発手順・構成・トラブルシュート | [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) |
