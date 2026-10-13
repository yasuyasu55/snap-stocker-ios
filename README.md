# SNAP STOCKER iOS（PoC・最小版）

確認したいのは次の2つだけです。
1. アプリ内ブラウザ(WKWebView)で Disney の商品ページが正常に表示できるか
2. 「画像取得」を1回押して、対象商品の画像枚数が取れるか

機能: URL入力 / 戻る・進む・更新 / 「画像取得」/ 枚数表示 / サムネイル一覧（解像度つき）/ UA切替ボタン
未実装: トリミング・写真保存・ZIP・CATALOG MASTER連携 など

> 注意: このコードは Swift のコンパイル環境がない場所で書かれており、**まだ一度もビルドされていません**。
> 最初の GitHub Actions 実行でビルドエラーが出る可能性があります（その場合はエラーログを貼ってください）。

## 1. GitHubに置くファイル
```
.github/workflows/build-ipa.yml
Config/            (空でOK。無ければ作らなくてよい)
SnapStocker/AppDelegate.swift
SnapStocker/BrowserViewController.swift
SnapStocker/Resources/extractor.js
project.yml
.gitignore
README.md
```
置き方: GitHubで新しいリポジトリ（Public推奨）を作り、「Add file → Upload files」にZIPを展開した中身を丸ごとドラッグ。
`.github` フォルダが上がらない時は、「Add file → Create new file」で名前欄に `.github/workflows/build-ipa.yml` と入力し、中身を貼り付けて保存。

## 2. ビルド方法（GitHub Actions）
1. リポジトリの「Actions」タブを開く
2. 「Build IPA (unsigned)」→「Run workflow」→ 緑のボタン（push した時も自動で動く）
3. 5〜10分待つ。緑のチェック＝成功、赤＝失敗（失敗ログをClaudeに貼る）

## 3. .ipa の取得場所
成功した実行の画面を下へスクロール →「Artifacts」の **SnapStocker-ipa** をクリック → ZIPが落ちる →
展開すると `SnapStocker.ipa`。

## 4. WindowsからiPhoneへ入れる最短手順（AltStore / AltServer）
1. Apple公式サイトから **iTunes** と **iCloud** を入れる（Microsoft Store版は不可）
2. AltStore公式サイトから **AltServer** を入れて起動（タスクトレイに出る）
3. iPhoneをUSBでつなぎ、「このコンピュータを信頼」→ iTunesで「Wi-Fi経由で同期」をON
4. AltServerのトレイアイコン → **Install AltStore** → iPhoneを選ぶ → Apple Account入力（捨てアカウント可）
5. iPhone: 設定 → 一般 → VPNとデバイス管理 → 自分のApple Accountを「信頼」
6. `SnapStocker.ipa` を入れる: AltServerのメニューの **Sideload .ipa…**（無い場合はSideloadlyで.ipaをドラッグ）
7. iPhone: 設定 → プライバシーとセキュリティ → **デベロッパモード** をON → 再起動
- 7日で期限切れ。AltStoreが同じWi-Fi上のPCで自動更新します。無料Apple Accountは同時3アプリまで。
- 手順の細部は各ツールの現行バージョンで異なる場合があります（未検証）。

## 5. iPhone実機での確認
1. SNAP STOCKER を開く → 自動で シェリーメイの商品ページ が開く
2. ページが正常に表示されるか確認（アプリ案内ページ等になっていないか）
   - おかしい時は右上の「UA:標準」を押して「UA:Safari風」に切替（自動再読込）
3. 商品画像が見える状態で、下の **画像取得** を1回押す
4. 上の状態表示を見る: 「N枚取得（本体 a / 要確認 b）・除外 c・ページ内img d・関連見出しあり/なし」
5. 下のサムネイルを確認:
   - 緑枠＝本体、橙枠＝要確認。各サムネの下に実際の解像度
   - 「一緒によく見られているグッズ」の画像が混ざっていないか
   - 取得失敗が出ていないか
6. 他のDisney商品でも、URL欄に入れて2〜5を繰り返す

### 記録してほしい項目
| 商品 | 表示OK? | 取得枚数 | 関連混入 | 解像度 | 失敗時の状態文 |
|---|---|---|---|---|---|

状態表示の文言（エラー含む）をそのままスクショで共有してください。
