# DSH Launcher — エージェント引き継ぎ

Windows 用の dsh（DeepSeek Harness）ランチャー。WPF/.NET 9 アプリと CLI が同一 exe。
作業ディレクトリはこのフォルダ。応対は日本語で行う。

## 必ず守ること

- **バージョン**: `<Version>` の更新と `dist\dshl.exe` の更新は**リリースを指示されたときだけ**
  行う（画面右下と `dshl --version` はアセンブリ由来）。通常の不具合修正ではバージョンを上げない。
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
  認証状態は `%APPDATA%\DshLauncher\pwa-auth.json` とウィンドウタイトルで判断する。対象は `127.0.0.1` の PWA のみ
  （dsh web の起動ログは実行中に排他ロックされるため、`?token=` URL の読み取りには頼らない）。
- **アプリ内更新**: `Update.cs`。`releases/latest` を確認し、実行中の exe と同じ種類のアセットを
  SHA256 検証してから、非表示 PowerShell ヘルパーで exe を差し替えて再起動する（インストーラは呼ばない）。
  UI はステータスバーの「v<ver> に更新」とトレイ通知、CLI は `dshl update [--check]`。
  更新先に書き込めない/別インスタンスが起動中なら実行しない。

## 詳細ドキュメント

| 内容 | 場所 |
|---|---|
| 使い方・現状・実測 | [README.md](README.md) |
| 設計・決定事項・デザイン | [DESIGN.md](DESIGN.md) |
| 開発手順・構成・トラブルシュート | [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) |
