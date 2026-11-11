# DSH Launcher — エージェント引き継ぎ

Windows 用の dsh（DeepSeek Harness）ランチャー。WPF/.NET 9 アプリと CLI が同一 exe。
作業ディレクトリはこのフォルダ。応対は日本語で行う。

## 必ず守ること

- **バージョン**: 変更したら `src/DshLauncher/DshLauncher.csproj` の `<Version>` を上げ、
  `dist\dshl.exe` を更新する（画面右下と `dshl --version` はアセンブリ由来）。
- **置き換え前**: 実行中の `dshl` は `dist\dshl.exe` をロックする。プロセスを停止してから publish。
- **dsh の起動方式**: タスクスケジューラ＋`wscript` の非表示ランチャーを維持する。
  アプリや SSH から `dsh web` を直接起動すると、CLI のパイプ待ちや SSH セッション終了で落ちる。
- **ローカル起動コマンド**: `dsh <profile> --port <port> --no-open`。
  `dsh web --profile web` は「プロファイル二重指定」で失敗する。
- **リモート Windows**: `.ps1` は UTF-8 BOM 付きで配置。`$Profile` は PowerShell の自動変数なので使わない
  （`$ProfileName`）。dsh は `%APPDATA%\npm\dsh.cmd` を優先（`.ps1` シムは cmd.exe で実行不可）。
- **UI**: 操作中（起動/再起動/停止/セットアップ）は一覧を再描画せず、経過テキストだけ更新する。
  再描画するとインジケータバーのアニメーションがリセットされる。
- **PWA を開く（Brave アプリ）**: **マシン非依存**。ボトムバー右とトレイ最上位に置き、CLI は `dshl pwa --open`。
  起動は `chrome_proxy.exe --profile-directory="Profile N" --app-id=<id>`（Start Menu と同じ行）。
  app id は manifest id（DSH は `start_url: "./"` = URL のディレクトリ）の**二重 SHA-256** から算出する。
  `.lnk` 解析・Brave 内部 DB は使わない。検出は `dshl pwa --json` で確認。

## 詳細ドキュメント

| 内容 | 場所 |
|---|---|
| 使い方・現状・実測 | [README.md](README.md) |
| 設計・決定事項・デザイン | [DESIGN.md](DESIGN.md) |
| 開発手順・構成・トラブルシュート | [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) |
