# DSH Launcher

DeepSeek Harness（dsh）を、このPCとリモートマシンで起動・再起動・停止・状態確認するための
Windows デスクトップアプリ（WPF / .NET 9）＋ CLI（`dshl`）。同じ exe が GUI と CLI を兼ねる。

![actual UI](design/v3/24-gui-pwa.png)

## ドキュメント

| 内容 | 場所 |
|---|---|
| セッション引き継ぎ（最小） | [AGENTS.md](AGENTS.md) |
| 設計・デザイン・決定事項 | [DESIGN.md](DESIGN.md) |
| 開発・構成・障害対応 | [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) |

## 実装状況（v0.1 / 2026-11-11）

| 機能 | 状態 |
|---|---|
| 一覧ウィンドウ（状態グループ・選択行の展開・集計） | ✅ 実装 |
| ローカル: 起動 / 再起動 / 停止 / 状態（PID・稼働時間・メモリ） | ✅ 実装・実機確認 |
| ローカルの表示名 `マシン名(local)` | ✅ `nzxt(local)` |
| マシン名の編集（右クリック → 名前を変更…、`dshl rename`） | ✅ 実装 |
| トレイ常駐（集計・マシン別サブメニュー・一括再起動・終了） | ✅ 実装 |
| 確認ダイアログ（対象・実行コマンド・現在状態） | ✅ 実装 |
| リモート: SSH 検出（OS / Node / dsh / ~/.dsh / ポート / 遅延） | ✅ 実機確認 |
| リモート: ヘルパー自動配置（`setup`） | ✅ 実機確認（minipc-server へ配置） |
| リモート: 起動 / 再起動 / 停止 | ✅ 実機確認（minipc-server を起動し HTTP 401 まで確認） |
| リモート: DSH の自動セットアップ（Node 24.9+ と dsh） | ✅ 実機確認（minipc-server: Node v24.13.0 / dsh 0.2.2-rc.1） |
| ログ表示（ローカルはファイル、リモートは tail） | ✅ 実装 |
| マシン追加（SSH エイリアス・ポート・プロファイル） | ✅ 実装 |
| PWA を開く（Brave アプリ、マシン非依存） | ✅ 実装・実機確認（DeepSeek Harness / Profile 5） |
| URL の編集 UI / フィルタ表示（9台以上） | ⏳ 次段 |

## 修正履歴（v0.1.9）

- PWA を開く導線を**マシンから独立**させ、ボトムバー右の主ボタンと**トレイの最上位**に置いた。名前は「**PWA を開く**」。
  行メニュー・選択行の展開・トレイのマシン別サブメニューからは外した（PWA はこのPCの DSH に属するもので、マシン行の操作ではないため）。
- CLI: `dshl pwa [--open] [--dry-run] [--json]` に整理（情報表示 / 起動 / 実行コマンド表示 / JSON）。
  v0.1.8 の `dshl open <machine> --app` と `dshl apps` は削除。
- 検出と起動の仕組みは v0.1.8 のまま（`chrome_proxy.exe --profile-directory="Profile N" --app-id=<id>`）。

## 修正履歴（v0.1.8）

- ローカル DSH の PWA（Brave アプリ）検出と起動を追加（v0.1.9 で導線をマシン非依存に変更）。
  - Brave の Web アプリは `chrome_proxy.exe --profile-directory="Profile N" --app-id=<id>` で起動する
    （Start Menu の `Brave Apps` ショートカットと同じ行）。
  - app id は **Web App Manifest の id を二重 SHA-256** した Chromium の a–p 記法。DSH は manifest に `id` が無く
    `start_url: "./"` なので、manifest id は URL のディレクトリ（既定はオリジン直下）。
    実測: `http://127.0.0.1:3080/` → `hgiemfgfjhalibdoboikeiepnnjapnpc`（存在の判定は
    `Web Applications\_crx_<id>` と `Manifest Resources\<id>`）。
  - PWA が未インストールなら案内ダイアログを出し、「Brave で開く」で URL をタブで開く。
  - SSH マシンは `url` 未設定だと `http://127.0.0.1:<port>/` に解決され、この PC の PWA と一致してしまうため対象外。
  - 起動は既存のブラウザ起動と同じく子プロセスを残さない（`UseShellExecute`。DSH 本体の起動だけがタスクスケジューラ経由）。

## 修正履歴（v0.1.7）

- 起動/再起動中のインジケータバーが「左から出て途中で消える」問題を修正。
  600ms ごとの一覧再描画でバーを作り直していたのが原因。操作中は**経過秒数のテキストだけ更新**し、
  バーのアニメーションを維持するようにした（再描画は操作完了時のみ）。リモート起動でも同様。

## 修正履歴（v0.1.6）

- 右下のバージョン表記を固定文字列 0.1 から**アセンブリのバージョン**（csproj の <Version>）表示に変更。
- CLI に dshl --version（および dshl version）を追加。現在は **v0.1.6**。
- 今後バージョンを上げるときは src/DshLauncher/DshLauncher.csproj の <Version> を更新して再ビルド。

## 修正履歴（v0.1.5）

- Windows リモートのセットアップ失敗を修正:
  - `.ps1` を **UTF-8 BOM 付き**で配置（BOM なしだと Windows PowerShell 5.1 が CP932 として読み、日本語入りスクリプトが構文エラーになる）。
  - Windows 側ヘルパーのパラメータ `$Profile` が PowerShell の**自動変数**と衝突していたため `$ProfileName` に改名。
  - `Get-Command dsh` が `.ps1` シムを返し `cmd.exe` から実行できなかったため、`%APPDATA%\\npm\\dsh.cmd` を優先。
  - SSH セッション終了で子プロセスが落ちるため、Windows リモートも **タスクスケジューラ + wscript 非表示起動**に統一。
- 例外メッセージを**コピー可能**に: ダイアログに「コピー」ボタン、本文・受領書は選択可能、ログ窓に「すべてコピー」。
- 実測: cpswhitegtx1080ti で Node v26.13.0 / dsh 0.2.2-rc.1 を導入 → 起動（HTTP 401）→ 停止（タスク・ポート掃除）まで確認。

## 修正履歴（v0.1.4）

- リモートマシンへの **DSH セットアップ** を追加。`dshl setup <machine> --install`、GUI は「要セットアップ」行のボタン／右クリック →「DSH をセットアップ…」。
  - Linux: nvm があれば `nvm install 24`、無ければポータブル Node 24 を `~/.dsh/runtime/node` に導入 → `npm i -g @deepseek-ai/dsh@latest` → ヘルパー配置。
  - Windows: Node 24.9+ を確認 → `npm i -g @deepseek-ai/dsh@latest` → ヘルパー配置。
  - 実行結果は画面のログ窓と `%APPDATA%\DshLauncher\logs\<id>-setup.log` に残る。
- リモートのヘルパーが nvm / ポータブル Node の PATH を自分で解決するように修正（非対話 SSH で dsh が見つからない問題）。
- リモート起動コマンドの誤り（`web --profile` 二重指定）を修正。

## 修正履歴（v0.1.3）

- 行内の「再起動 / 停止 / 起動」ボタンの余白を拡大（高さ28px・左右パディング14px・最小幅64px・ボタン間8px・行パディング10px・行高38px）。

## 修正履歴（v0.1.2）

- 起動/再起動/停止中に**進行表示**を追加: 行内に「起動中 12s」などの経過秒数とインジケータバー（WPFアニメーション）、下部ステータスバーに「更新中…」表示とバー。
- 起動用のターミナル窓が残る問題を修正: Task Scheduler のアクションを wscript.exe 経由の**非表示ランチャー**（run-<id>.vbs）に変更。
  停止時にタスクと残った cmd ラッパーを掃除するので、旧バージョンが開いた窓も停止/再起動で消えます。

## 修正履歴（v0.1.1）

- ダイアログのボタンが反応しない問題を修正（ウィンドウ全体の DragMove() がマウスを掴み、Border 疑似ボタンのクリックを飲んでいた）。ボタンを本物の Button（ControlTemplate 付き・UIAutomation 対応）に変更し、ドラッグは非インタラクティブ領域のみに限定。
- キャンセルでダイアログが閉じない問題も同根で解消。実機で「キャンセル→PID不変」「再起動→PID変更」を確認。
- 受領書のコマンド表記を dsh <profile> --port <port> --no-open に短縮。

## 起動

```powershell
# GUI（トレイ常駐）
C:\Users\koboy\Documents\dsh-launcher\dist\dshl.exe

# CLI（同じ exe）
dshl status [machine] --json
dshl start|stop|restart [machine] [--dry-run] [--json]
dshl machines / url / logs / setup / rename / add / remove
dshl open [machine] [--dry-run]
dshl pwa [--open] [--dry-run] [--json]
dshl gui
```

- **PWA を開く**: ボトムバー右の「PWA を開く」、または `dshl pwa --open`。
  Brave の PWA（このPCの DSH）を独立ウィンドウで開く。未インストールならインストール手順を案内する。

- 設定: `%APPDATA%\DshLauncher\hosts.json`（秘密情報なし。SSH は `~/.ssh/config` のエイリアスを使用）
- ローカル起動は **タスクスケジューラ経由**（`DshLauncher\start-<id>`）。サーバーがランチャーの
  プロセスツリーから外れるため、CLI をパイプで使っても待たされず、ランチャーを閉じても残る。
- ローカル起動時のログ: `%APPDATA%\DshLauncher\logs\<id>.log`
- リモートのヘルパー: `~/.dsh/dshl/agent.sh`（POSIX）/ `agent.ps1`（Windows）。`dshl setup <machine>` で配置。
- 終了コード: `0` ok / `1` error / `2` no change / `3` unreachable / `4` needs setup

## 構成

```
dsh-launcher/
├─ DESIGN.md              # 監査・方向・9パス・リモート設計・CLI仕様・決定事項
├─ design/
│  ├─ v1/ v2/ v3/         # デザインの変遷（v3 が確定、15-gui-window.png は実機）
├─ mockups/v0/            # 最初の3案（比較用）
├─ src/DshLauncher/       # WPF (.NET 9) 実装
│  ├─ Program.cs          # GUI/CLI 分岐（WinExe + コンソール接続）
│  ├─ Model.cs            # 設定・状態・ポート検出
│  ├─ Local.cs            # ローカル起動/停止/状態（タスクスケジューラ起動）
│  ├─ Remote.cs           # SSH・リモート検出/操作・ヘルパースクリプト
│  ├─ BraveApp.cs         # Brave アプリ（PWA）の検出と起動（app id 算出・プロファイル走査）
│  ├─ Cli.cs              # dshl サブコマンド
│  ├─ Ui.cs               # 一覧ウィンドウ・トレイ・テーマ
│  └─ Dialogs.cs          # 確認・名前変更・マシン追加・ログ
└─ dist/dshl.exe          # ビルド済み単一ファイル（.NET 9 Desktop Runtime 使用）
```

## 実測メモ

| ホスト | OS | Node | dsh | 状態 |
|---|---|---|---|---|
| このPC（nzxt(local)） | Windows | v24.18.0 | 0.2.2-rc.1 | 稼働中 |
| minipc-server | Linux | v24.13.0 | 0.2.2-rc.1 | 停止（セットアップ・起動/停止まで実機確認） |
| cpswhitegtx1080ti | Windows | v26.13.0 | 0.2.2-rc.1 | 停止（セットアップ・起動/停止まで実機確認） |









