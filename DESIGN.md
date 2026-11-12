# DSH Launcher — 設計

DeepSeek Harness を「このPC」と「リモートマシン」の両方で起動・再起動・停止・状態確認するための
Windows デスクトップアプリ（WPF / .NET 9）と、同じ exe に同居する CLI（`dshl`）。

- 作業ディレクトリ: `C:\Users\koboy\Documents\dsh-launcher`
- デザイン: `design/`（unslop 適用後の3画面）
- 旧デザイン: `mockups/v0/`（比較用）
- 実装予定: `src/`

---

## 1. unslop 監査（v0 モック）

v0（`mockups/v0/`）に対して `unslop` の signs.md を当てた結果:

| 分類 | 見つかった sign | 場所 |
|---|---|---|
| 面と色 | 青→明青のグラデーションボタン | A/B の主ボタン |
| 面と色 | 色付きグロー（`box-shadow` の青・緑） | 主ボタン、ステータスドット、リング |
| 面と色 | 放射状の色ウォッシュ背景（青・緑） | B/C の背景 |
| 面と色 | 角丸チップの多用（radius 999） | A/B/C のメタ情報 |
| 文字 | 700〜800 の見出し、ワードマーク 800 | A/B |
| 文字 | 大文字＋広いトラッキングのラベル（`DSH LAUNCHER`） | A/B |
| 文字 | 数字表記の混在（`3時間12分` / `3h 12m`） | A/B |
| アイコン | アイコンセットが無く、テキストのみ＋擬似ロゴ | 全体 |
| 間隔 | 4px グリッド外の値（26/30/54/76px）、A の大きな空白帯 | A/B |
| コピー | 同じ操作の表記ゆれ（`URLをコピー` / `コピー`、`ブラウザ` / `ブラウザで開く`） | A/B |
| 構成 | 同じ高さのボタンが並ぶだけ、製品固有の moment が無い | 全体 |
| 視覚 | 装飾的なグラデーション塊・光るリング | B/C |
| モーション | 呼吸するグロー（`animate-pulse` 相当） | ステータスドット |
| テンプレ | 製品名を他社に変えても成立する画面 | 全体 |

**判定: heavy slop**（色・文字・アイコン・コピー・構成の全層に sign）。9パスの全面適用とした。

## 2. 方向（direction）

- **Product**: DeepSeek Harness を、このPCとリモートマシンで起動・再起動・停止する小さな運用パネル。
  対象は dsh を常駐サービスとして使う人。
- **Character**: calm, exact, operational（静か、正確、運用向き）。
- **World**: 夜勤の計器盤。グラファイトの筐体、刻印されたラベル、指示灯、等幅の読み取り値。
- **Moments**: ①マシン一覧の指示灯と遅延の読み取り、②実行されるコマンドをそのまま見せる「コマンド受領書」、
  ③実ログの末尾。
- **Signature**: 破壊的・主要な操作の前に、**実行されるコマンドを等幅で必ず見せる**（コピー可）。
  CLI でも `--dry-run` が同じ行を返す。これがこの製品だけの一貫したディテール。

## 3. 適用した9パス

1. **Spacing** — 4px グリッド。sidebar 256 / header 56 / 行 36 / セクション間 20 / カード内 16〜20。
   旧モックの 26・54・76px を排除。
2. **Color** — graphite ランプ（`#0f0f10` sidebar / `#141415` page / `#19191b` card / `#232325` raised）に統一。
   色は意味だけ: 稼働 `#4cc38a`、要対応 `#d9a441`、停止 `#5a5a60`、異常 `#e5484d`。グロー・グラデーション・
   色付き影・放射ウォッシュを全廃。主ボタンは off-white（`#ededed`）＋濃色文字。
3. **Icons** — lucide 相当の線アイコン 16px / stroke 1.5 に統一（play, rotate-cw, square, external-link,
   copy, terminal, plus, chevron）。絵文字・擬似ロゴ塊を削除。ブランドは `>_` グリフ＋ワードマークのみ。
4. **Copy** — 事実だけ。見出しは「稼働中」「セットアップが必要」など状態語。`!` と末尾ピリオドなし。
   表記ゆれを解消（「コピー」「ブラウザで開く」）。数値は実測値（PID 55832 / 3080 / v20.19.0 / 42ms）。
5. **Type** — インターフェースは Segoe UI Variable Text / Yu Gothic UI、読み取り値は Cascadia Mono。
   ウェイト 400/500（600 は使わない）。サイズは 11/12/13/14/15/24/28。数字は `tabular-nums`。
   大文字トラッキングラベルを廃止。
6. **Layout** — アプリ比率（sidebar 256＋可変、padding 24、ヘッダ 56）。狭い中央カラムにしない。
   3画面: メイン（ローカル稼働）、リモート（要セットアップ）、トレイ＋確認ダイアログ。
7. **Details** — 半径は入れ子計算（窓12 / カード12 / ボタン8 / 入力8 / キーキャップ4）。
   ヘアラインは 8〜14% の白。カウントは等幅の静かなテキスト。キーキャップは小さく。
8. **Visuals** — 装飾ビジュアルを置かない。代わりに製品の実物（実ログ、実コマンド、指示灯、遅延）を
   moment にする。ヒーロー画像は使わない。
9. **Motion** — 常時ループ・呼吸グローを廃止。状態変化・ホバーのみ 120〜180ms、イージングは
   `cubic-bezier(0.22, 1, 0.36, 1)` の1本。レイアウトプロパティはアニメーションしない。

チェックリスト（unslop）: 方向の反映 / 4px / 整列 / 3テキストロール＋1アクセント / グラデ・グロー無し /
絵文字無し / 1アイコンセット / ウェイト400-500 / コピー規約 / 等幅数字 / 入れ子半径 / 実ビジュアル /
モーション — すべて適合。

## 4. 画面と状態

| 画面 | 内容 | 状態 |
|---|---|---|
| `design/01-main-local.png` | このPC 稼働中。PID/ポート/稼働時間/メモリ、URL、実行コマンド、実ログ | 稼働 |
| `design/02-remote-setup.png` | minipc-server。SSH 42ms、Node 20.19（要 24.9+）、dsh 未導入、手順3ステップ | 要セットアップ |
| `design/03-tray-confirm.png` | トレイメニュー（マシン別サブメニュー）＋再起動確認（対象・コマンド・現在状態） | 操作 |

マシン状態は4つ＋能力状態2つ:

- 稼働中 / 起動中 / 停止 / 到達不可
- 要セットアップ（dsh 未導入・Node 不足）/ 要設定（URL・プロファイル未設定）

## 5. リモート対応アーキテクチャ

### 5.1 前提（実測）

| ホスト | OS | Node | dsh | ~/.dsh | 3080 |
|---|---|---|---|---|---|
| このPC | Windows | v24.18.0 | 0.2.2-rc.1 | あり | 稼働中 |
| minipc-server | Linux | v20.19.0（不足） | 未導入 | あり（profiles/storages） | 閉 |
| cpswhitegtx1080ti | Windows | v26.13.0 | 未導入 | あり | 閉 |

→ リモートは「dsh が入っていない状態」から始まるため、**状態検出とセットアップ導線**が必須。

### 5.2 トランスポート

- **SSH**（Windows 標準の `ssh.exe`、`~/.ssh/config` のエイリアスをそのまま使う）。
- 認証は鍵/ssh-agent のみ。パスワードは保存しない（`BatchMode=yes`、`ConnectTimeout=5`）。
- ホスト鍵は追加時にフィンガープリントを表示して確認（TOFU）。`known_hosts` はユーザーのものを使う。
- 状態の軽量チェックは SSH の応答時間と、`dsh` の有無・Node バージョン・ポートの3点。

### 5.3 リモートヘルパー（操作）

操作（start/stop/restart/logs）は、リモートに置く小さなヘルパーで行う。

- `~/.dsh/dshl/agent.sh`（POSIX sh、Linux/macOS）: `status|start|stop|restart|logs` を実装。
  `dsh web` を `setsid nohup` で起動し、PID とログを `~/.dsh/dshl/` に保持。停止は pidfile の
  プロセスグループを終了。出力は JSON（`{"state":"running","pid":...,"port":...}`）。
- `%USERPROFILE%\.dsh\dshl\agent.ps1`（Windows リモート）: 同じ語彙を PowerShell で実装。
- 配置は「セットアップ」ボタンから SSH 経由で書き込む（数KB・監査可能）。自動インストールはしない。
- ヘルパーが無いホストでも、**状態確認のみ**は SSH のプローブで可能（読み取り専用）。

### 5.4 設定

`%APPDATA%\DshLauncher\hosts.json`（秘密情報なし）:

```json
{
  "machines": [
    {"id":"local","label":"このPC","transport":"local","profile":"web","port":3080,
     "url":"https://nzxt.tail34c6a3.ts.net/"},
    {"id":"minipc","label":"minipc-server","transport":"ssh","sshAlias":"minipc-server",
     "platform":"linux","profile":"web","port":3080,"identityFile":null}
  ]
}
```

### 5.6 リモートへの DSH セットアップ（v0.1.4）

- dshl setup <machine> --install / GUI「DSH をセットアップ…」で実行。
- Linux: nvm があれば 
vm install 24。無ければポータブル Node 24 を ~/.dsh/runtime/node に導入（nodejs.org の latest-v24.x）。
  その後 
pm i -g @deepseek-ai/dsh@latest（失敗時は --prefix ~/.dsh/npm-global）→ ヘルパー配置。
- Windows リモート: Node 24.9+ を確認 → 
pm i -g @deepseek-ai/dsh@latest → ヘルパー配置。
- ヘルパー/起動は nvm・ポータブル Node の PATH を自分で解決する（非対話 SSH 対策）。
- 実行結果は UI のログ窓と %APPDATA%\DshLauncher\logs\<id>-setup.log に保存。
- 実測: minipc-server を Node v20.19/未導入 → Node v24.13.0/dsh 0.2.2-rc.1 に更新し、起動（HTTP 401）まで確認。

### 5.5 失敗時の扱い

- SSH 到達不可 → 「到達不可」表示。3回失敗でバックオフ（次の手動更新まで再試行しない）。
- dsh 未導入 → 「要セットアップ」＋手順（自動インストールはしない）。
- Node 不足 → 「Node 24.9 以上が必要」＋コマンド提示。
- 停止後の起動失敗 → ログ末尾と終了コードを受領書の下に表示。

### 5.7 PWA を開く（ブラウザの Web アプリ、v0.1.13）

DSH の Web GUI は PWA を配信している（`/manifest.webmanifest`、`display: standalone`、`start_url: "./"`）。
Chromium 系ブラウザの「アプリとしてインストール」で作った Web アプリは独立ウィンドウで常駐するため、
ランチャーからはタブではなくそのウィンドウを開きたい。

- **マシン非依存**: Web アプリは 1 つのオリジン（このPCの DSH）に属する。マシン行の操作ではなく、
  **ボトムバー右の主ボタン「PWA を開く」**と**トレイ最上位の「PWA を開く」**に置く。
  行メニュー・選択行の展開・マシン別トレイサブメニューには出さない。
- **名前**: 「PWA を開く」。ユーザー向けの文言は**特定ブラウザ名を出さず「ブラウザ」に統一**する
  （環境によって使うブラウザが違うため）。
- **対象ブラウザ**: Chromium 系（Chrome / Edge / Brave / Chromium）。Firefox など Web アプリを
  インストールできないブラウザは対象外。Brave は Beta / Dev / Nightly も探索する。
- **起動方式**: ブラウザ同梱の app launcher（`chrome_proxy.exe` / `msedge_proxy.exe`。無ければブラウザ exe）に
  `--profile-directory="Profile N" --app-id=<id>` を渡す。Start Menu のブラウザのアプリショートカットと同じ行。
- **app id の算出**: Chromium の Web App ID は `GenerateId(SHA256(manifest_id))`。
  `GenerateId` は SHA256 の先頭 16 バイトを `a`–`p` の 32 文字に写像するので、
  実質 **manifest id の二重 SHA-256**。DSH の manifest は `id` を持たず `start_url: "./"` なので、
  manifest id は manifest を配信しているディレクトリ = オリジン直下（例 `http://127.0.0.1:3080/`）。
  URL から決まり、ネットワークにもブラウザの内部 DB にも依存しない。
  ローカル DSH は `127.0.0.1` / `localhost` の両表記を試す。
- **インストールの判定**: `<User Data>\<Profile>\Web Applications\_crx_<id>`（アイコン。ファイル名が表示名）または
  `Manifest Resources\<id>` が実在するか。Edge は `_crx__<id>`（アンダースコア2つ）なので両対応。
  プロファイルは `Default` → `Profile N` の順。ブラウザの探索は App Paths レジストリ＋
  Program Files / LocalAppData の既知配置。
- **未インストール時**: 勝手にインストールしない。案内ダイアログを出し、「ブラウザで開く」で
  既定のブラウザに URL を開く。
- **初回認証（v0.1.14）**: DSH の Web UI は署名つき HttpOnly クッキー（`dsh-auth-<authority の SHA-256>`）で保護される。
  dsh web は起動時に `?token=` 付き URL を表示するが、その出力（ランチャーが捕捉するログ）は dsh 実行中に
  排他ロックされて読めない。そこで **`$DSH_HOME/.credentials.yaml` の browser-session secret から
  同じクッキーを再生成**し、`127.0.0.1` の一時ページ（クッキーはポート非依存）を
  **非表示のアプリウィンドウ**で開いて設定する（タブ・ウィンドウは残らない）。設定前にサーバーへ
  Cookie ヘッダで 200 を確認する。対象は `http://127.0.0.1:<port>` の PWA（ループバック限定）。
- **認証状態の判断**: PWA のウィンドウタイトル（401 は authority 表示、認証済みはアプリ名を含む）と、
  `%APPDATA%\DshLauncher\pwa-auth.json`（ブラウザ・プロファイル・authority・有効期限）の両方で判断する。
  401 を検知した場合だけ認証を更新し、PWA を開き直す（無駄なタブやウィンドウを出さない）。
- **CLI**: `dshl pwa`（検出情報）/ `--open`（起動。自動認証込み）/ `--dry-run`（実行行のみ）/ `--json`。
  JSON は `browser` / `browsers` / `authenticated` / `authAvailable` を含む。
  未インストールは終了コード `4`（要セットアップ）。
- **決定**: `.lnk` の解析・ブラウザの内部 DB は読まない。URL から決まる app id と
  `Web Applications` の実フォルダだけを見る（壊れにくく、説明できる）。
  認証だけは dsh のクッキー仕様に依存するため、対象をループバック PWA に限定し、失敗時は従来どおり
  案内にフォールバックする。

## 6. CLI（`dshl`、GUI と同一 exe）

```
dshl status [machine] [--json] [--all]
dshl start|restart|stop [machine] [--yes] [--dry-run] [--json]
dshl machines [--json]
dshl url [machine]
dshl logs [machine] [-n 50]
dshl setup <machine>          # ヘルパー配置のみ
dshl open [machine] [--dry-run]              # 既定ブラウザで URL を開く
dshl pwa [--open] [--dry-run] [--json]       # PWA（ブラウザの Web アプリ）の情報 / 起動
```

- `--dry-run` は実行するコマンド（受領書と同じ行）を出力して終了。
- 終了コード: `0` 成功 / `2` 既に稼働・停止 / `3` 到達不可 / `4` 要セットアップ / `1` その他。
- 他AI・リモートDSHからの利用例: `ssh <host> dshl restart minipc --yes --json`。

## 7. 実装計画（WPF / .NET 9）

1. **コア**: `DshControl`（プロセス/ポート/SSH/設定/状態機械）。GUI 非依存で CLI と共有。
2. **ローカル**: 起動＝`dsh web --profile <p> --port <port>` を Job Object 付きで起動（`hc` があれば
   `hc run --bg` を優先）。停止＝ポート占有 PID のツリー終了。状態＝TCP 接続＋応答コード。
3. **リモート**: SSH プローブ、ヘルパー配置、操作、ログ取得。すべて非同期＋キャンセル可能。
4. **UI**: 画面 01/02/03、トレイ常駐（NotifyIcon）、状態ポーリング（5秒→失敗時バックオフ）。
5. **CLI**: 引数分岐、`--json`、終了コード、`--dry-run`。
6. **検証**: lab 環境（別 DSH_HOME・別ポート）で start/stop/restart、minipc-server で読み取り専用プローブ。

## 8. v2 — コンパクト化（フィードバック反映）

v1 への指摘「機能に対してウィンドウが贅沢（リッチすぎる）」を受け、**同じ機能をより小さく密に**作り直した。

| | v1 | v2 |
|---|---|---|
| メイン窓 | 1120×720（サイドバー256＋詳細ペイン＋大型ステータスカード＋ログ欄） | **480×348**（マシン一覧＋選択行のインライン展開のみ） |
| 単一マシン表示 | — | **420×344**（ホスト切替タブ＋状態＋操作＋ログ2行＋受領書） |
| 状態の見せ方 | 24px の状態語＋4分割の事実カード | 12.5px の行内表記＋等幅の1行メタ |
| ログ | 常時5行のパネル | 単一マシン表示で2行（メイン窓は「ログ」リンク） |
| 受領書 | 独立セクション | 選択行の展開内／下部に1行 |
| 確認ダイアログ | 460px | 404px |
| 余白 | セクション間 20、カード内 20 | セクション間 8〜10、行 30〜38 |

変更点（9パスのうち spacing / layout / details を再適用）:
- 情報の階層を「一覧 → 選択行の展開」に変更し、常時表示の大型パネルを廃止
- 行 38px・タブ 26px・ボタン 24〜30px・ヘッダ 30px に統一
- 数字・URL・コマンドは等幅 11px に落とし、事実カードを1行メタに統合
- 空き帯を排除（v1 の「余白のぜいたく」を解消）
- 製品の moment（受領書・実ログ）は維持

画面: `design/v2/10-compact-list.png` / `11-compact-single.png` / `12-tray-confirm.png`
（v1 は `design/v1/` に退避）

## 9. 決定済み事項

- リモート操作: **ヘルパーを自動配置**（`~/.dsh/dshl/agent.sh` / `agent.ps1` を SSH で書き込む）
- テーマ: **ダーク固定**（graphite ランプ）
- リモートのセットアップ: 手順表示＋ワンクリックコピー（Node/dsh の自動インストールはしない）
- 起動方式: `hc` があれば herdr-app 経由、無ければ可視コンソール（前回方針を踏襲）
- PWA を開く: **マシン非依存**でボトムバー右＋トレイ最上位（名前は「PWA を開く」、UI は「ブラウザ」表記）。
  URL → app id を二重 SHA-256 で算出し、Chromium 系ブラウザ（Chrome / Edge / Brave / Chromium）から
  検出した Web アプリを同梱の proxy exe で起動する。未インストール時は案内のみ（5.7）
- 配布: GitHub Releases（自己完結 exe を推奨 ＋ framework-dependent 軽量版、`install.ps1`、SHA256SUMS）。
  `v*` タグ push で Actions がビルドして Release を作成する（12）
- ライセンス: **MIT**。非公式ツールであることを README と Release 本文に明記し、上流の
  [ブランドガイドライン](https://github.com/deepseek-ai/deepseek-harness/blob/master/BRAND_GUIDELINES.md) に従う
  （プロジェクト名は「DSH」、フルネーム「DeepSeek Harness」は互換性の説明にのみ使用）。

## 10. 決定済み: 画面構成 = A + C ハイブリッド

B（単一マシン型・タブ切替）は**マシン数が増えると破綻する**ため不採用。A（一覧）＋C（トレイ）の
ハイブリッドを採用する。

### A — 一覧ウィンドウ（480×420、マシン多数対応）

- 状態でグループ化: **稼働中 / 要対応 / 停止**（セクションラベル 10.5px、前 8px・後 5px）
- 行 36px。選択行だけが詳細（URL・PID・受領書）をインライン展開
- **8 台を超えたら絞り込み欄**を表示（`名前で絞り込み` と件数）。常時表示はしない
- リストはスクロール（WPF は `ListBox` の仮想化）。下部は固定（+ マシンを追加 / ログ / 設定）
- ステータスバーに集計: `8 台中 2 台稼働 · 3 台要対応`
- 空き帯なし。行内の操作ボタンは選択行のみ

### C — トレイメニュー（マシン多数対応）

- ヘッダに集計（`8 台中 2 台稼働 · 3 台要対応`）
- トレイに出すのは **稼働中＋直近に使った最大 3 台**まで。それ以上は `すべてのマシン…` で A を開く
- 各マシンはサブメニュー: ブラウザで開く / 再起動 / 停止 / ログを開く / 詳細（一覧を開く）
- 一括操作は `稼働中をまとめて再起動…`（確認ダイアログ経由）
- 確認ダイアログは v2 の 404px 版を流用（対象・実行するコマンド・現在状態）

画面: `design/v3/13-list-many.png`（A・8台）、`design/v3/14-tray-submenu.png`（C・サブメニュー）、
確認ダイアログは `design/v2/12-tray-confirm.png`

## 11. 未決事項

- 実装着手のタイミング（デザインは確定）

## 12. 配布（v0.1.10）

他のPCへ配布できる形にする。ランチャー自体は単一 exe（設定は `%APPDATA%`）なので、インストーラは
「配置＋ショートカット」だけを担い、レジストリ・PATH・サービスを触らない。

- **Releases**: `.github/workflows/release.yml` が `v*` タグ push でビルドし Release を作成
  （タグと csproj の `<Version>` が一致しない場合は失敗）。
  - `dshl-<ver>-win-x64.exe`: 自己完結（.NET 不要、約 70MB）。推奨。
  - `dshl-<ver>-win-x64-framework-dependent.exe`: 約 0.5MB。.NET 9 Desktop Runtime が必要。
  - `install.ps1` と `SHA256SUMS.txt` を同梱。
- **install.ps1**: latest の exe を取得 → SHA256 照合 → `%LOCALAPPDATA%\Programs\DshLauncher` に配置 →
  スタートメニューにショートカット。自分自身と `update.cmd` / `uninstall.cmd` も配置先にコピーし、
  既定の実行ポリシー（Restricted）でも更新・削除できるようにする。
- **アイコン**: `src/DshLauncher/app.ico`（`tools/make-icon.py` で生成）。**DSH の文字マーク**
  （`>_` のプロンプト記号はターミナルエミュレーターに見えるため廃止）。ウィンドウ・トレイ・ショートカットを同じ意匠に。
- **署名**: なし。初回実行時の SmartScreen 警告は README で案内する。

---

*デザインは unslop（Damir Sokolovsky, CC BY 4.0）の手順に従って作成。*

