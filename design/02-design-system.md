# Lay X — Design System: "Glass Studio"

Native AI. Beautifully local.

Status: 方向性(D — Glass Studio)承認済み / 細部レビュー中。本実装は未着手。
Screens: `design/screens/D-*.png`

---

## 0. 原則

1. **Glass is the frame, not the content.** ガラス(半透明 + blur)はウィンドウ枠とパネルだけに使う。本文・コード・表は不透明に近い暗面に置き、可読性を優先する。
2. **Engineer-grade, not cluttered.** 数値は等幅・tabular で正確に見せるが、常時表示は「TTFT / tok/s / メモリ」の3つまで。詳細は Inspector(⌘I)や Performance 画面に逃がす。
3. **Tight geometry.** 角丸は最大 12。カプセル・球体は使わない。
4. **No solid fills.** 主ボタン・選択・トグルも含めて、アクセント色はすべて半透明のガラスで表す(下の `accent.glass`)。紫のベタ塗りは使わない。
5. **Light only where something is alive.** シアン→インディゴのグラデーションと発光は「生成中」「接続中」「選択中」にだけ使う。
6. **Temporary by default, visibly.** 一時チャットは常に `TEMP` で示し、ピン留めだけが永続化される。
7. **Keyboard first.** 主要操作にはすべてショートカットを付け、キーキャップとして UI 上に見せる。
8. **Nothing changes on disk without consent.** Work は「提案 → Diff → 承認」の順。API サーバーは初期状態で localhost のみ公開。

---

## 1. Color

### 1.1 Backdrop(ウィンドウ背景)
| Token | Value | 用途 |
|---|---|---|
| `bg.base` | `#0A0B11` | ウィンドウの最下層 |
| `bg.glow.primary` | `rgba(58,46,158,.55)`(`#3A2E9E`)左上 radial 620×520 | 暗めの深い紫の光 |
| `bg.glow.secondary` | `rgba(170,150,240,.16)` 右下 radial 820×600 | ごく薄いラベンダー |

> 実装では、壁紙が透ける `NSVisualEffectView(.underWindowBackground)` の上に 2 つの radial gradient を 1 枚の `Canvas` / `MeshGradient` として重ねる。

### 1.1a Background glow presets(Settings → Appearance)
左上の光の色はユーザーが選べる。右下の薄い光は、選んだ色に合わせて変わる。
| Preset | 左上(濃い光) | 右下(薄い光) |
|---|---|---|
| Deep Violet(既定) | `#3A2E9E` α.55 | `#AA96F0` α.16 |
| Plum(濃い赤紫) | `#6A1E55` α.55 | `#E0A0C8` α.13 |
| Graphite(ごく濃いグレー) | `#2B2D35` α.70 | `#B8BAC4` α.08 |
| Midnight | `#1B2F6B` α.60 | `#9FB4F0` α.13 |
| Deep Teal | `#0E4A4E` α.60 | `#8FD6D0` α.11 |

アクセント色(`#8FA0FF`)はどのプリセットでも同じ。選んだ値は `lx.glowPreset` に保存する。

### 1.1b Glass transparency(Settings → Appearance)
ユーザーがスライダーで 0–100% に調整できる(既定 50%、`UserDefaults` の `lx.glassTransparency` に保存)。t = 0…1 として:
- パネル/Mini の色の濃さ(tint)の倍率 = `1.6 − 1.2t`(既定で 1.0)
- 壁紙の上に重ねる `bg.base` の不透明度 = `0.97 − 0.17t − 0.5t²`(既定でおよそ 0.76)
- 文字のコントラスト確保のため、本文やコードの下地(`surface.well` / `surface.code`)はこの設定の影響を受けない。

### 1.2 Surfaces
| Token | Value | 用途 |
|---|---|---|
| `surface.pane` | `rgba(26,28,40,.42)` + blur 36 + saturate 1.5 | サイドバーのパネル |
| `surface.content` | `rgba(14,15,24,.50)` + blur 36 | メインのコンテンツパネル |
| `surface.well` | `rgba(0,0,0,.22)` | カード、入力欄、メーター |
| `surface.code` | `rgba(4,5,10,.55)` | コード・Diff |
| `surface.overlay` | `rgba(20,22,34,.94)` | ツールチップ、ポップオーバー |
| `surface.mini` | `rgba(18,20,30,.62)` + blur 40 | Mini Chat パネル |

### 1.3 Strokes(すべて 1px の inset)
| Token | Value |
|---|---|
| `stroke.edge` | `rgba(255,255,255,.08)` |
| `stroke.highlight`(上辺のみ) | `rgba(255,255,255,.11)` |
| `stroke.divider` | `rgba(255,255,255,.06)` |
| `stroke.row` | `rgba(255,255,255,.04)` |

### 1.4 Text
| Token | Value | 用途 | `#14151F` 上でのコントラスト |
|---|---|---|---|
| `text.primary` | `#F0F1F6` | 見出し、値 | 16.1:1 |
| `text.body` | `#DADCE6` | 本文 | 13.3:1 |
| `text.secondary` | `#A3A6B6` | 説明、ラベル | 7.5:1 |
| `text.tertiary` | `#868A9C` | メタ情報、時刻、ショートカット、単位 | 5.3:1 |

### 1.5 Accent & Signal
| Token | Value | 用途 |
|---|---|---|
| `accent` | `#8FA0FF`(Lay Indigo) | 主ボタン、選択、トグル ON |
| `accent.tint` | `rgba(143,160,255,.13)` + edge `.18` | 選択中の行の背景 |
| `accent.glass` | 縦グラデーション `rgba(143,160,255,.30 → .14)`、枠 `rgba(143,160,255,.42)`、上辺 `white .18`、発光 `0 0 18 / .16`、文字 `#EEF0FF` | Send、主ボタン、ピン留め中 |
| `accent.glass.control` | `rgba(143,160,255,.38)` + 枠 `.55` | トグル ON、チェックボックス ON |
| `accent.text` | `#A9B4FF` | リンク、アイコン(選択中) |
| `live.gradient` | `#7DE3FF → #8F7CFF` | モデルのアイコン、生成中のリボン |
| `live.cyan` | `#7DE3FF` | ストリーミング中のテキスト |
| `status.ok` | `#5EE3B0` | 接続中、200、追加行 |
| `status.warn` | `#F2C46D` | LAN 公開の警告、変更ファイル |
| `status.error` | `#FF8A8A` / bar `#FF6B6B` | 4xx/5xx、削除行、破壊的操作 |
| `syntax.keyword` | `#B9A6FF` |
| `syntax.type` | `#86E1F2` |
| `syntax.string` | `#FFB09A` |
| `syntax.number` | `#F2D58A` |

### 1.6 Data visualization(カテゴリー色。この順に固定で割り当てる)
| Slot | Value |
|---|---|
| 1 | `#1E98B8` cyan |
| 2 | `#7F68DC` violet |
| 3 | `#B47E24` amber |

ダークの面 `#12131C` に対して検証済み(明度帯 / 彩度 / 色覚多様性での区別 ΔE ≥ 9.3 / コントラスト ≥ 3:1)。系列が 4 つ以上になる場合は「Other」にまとめる。状態色(ok/warn/error)は系列色として使わない。

---

## 2. Typography

UI は SF Pro(デザインモックでは Inter で代用)、日本語はヒラギノ角ゴ、数値とコードは SF Mono。

| Token | Size / Line | Weight | 用途 |
|---|---|---|---|
| `display` | 24 / 30, −0.02em | Semibold | 空状態の見出し |
| `title` | 14 / 20 | Semibold | 画面タイトル(ヘッダー) |
| `body.lg` | 14 / 24 | Regular | チャット本文(日本語は 1.7 前後) |
| `body` | 13 / 20 | Regular | UI 全般、リスト行 |
| `body.sm` | 12.5 / 19 | Regular | 表、説明 |
| `caption` | 11.5 / 16 | Regular | 補足 |
| `label` | 10.5–11 / 14, +0.08em, UPPERCASE | Semibold | セクション見出し |
| `mono.lg` | 24 / 28 | Medium | KPI の数値 |
| `mono` | 12–12.5 / 20 | Regular | コード、Diff |
| `mono.sm` | 10.5–11 / 14 | Regular | メトリクス、時刻、ショートカット |

ルール:
- 本文テキストのコントラストは最低 4.5:1(`text.tertiary` 以上の明るさ)を守る。
- すべての数値は `.monospacedDigit()`(tabular)にする。
- 単位は値より 1 段小さく、`text.tertiary` で表示する(例: `48.6 tok/s`)。
- 英語と日本語を混ぜる本文は行間 1.65–1.75 にする。

---

## 3. Spacing(4pt grid)

| Token | pt | 主な用途 |
|---|---|---|
| `space.1` | 4 | アイコンとテキストの最小間隔 |
| `space.2` | 8 | **ウィンドウ内側の余白と、パネル間の隙間** |
| `space.3` | 12 | カード内、行間 |
| `space.4` | 16 | 画面の余白 |
| `space.5` | 20 | チャットのメッセージ間隔 |
| `space.6` | 24 | セクション間 |

固定寸法:
| 要素 | 値 |
|---|---|
| ヘッダー高 | 48 |
| リスト行・ナビ行 | 30 |
| 表の行 | 38(ヘッダー 30) |
| ボタン | 28(小 24) |
| 入力欄(フィールド) | 28 |
| Composer | 約 92(入力 + ツールバー 38) |
| Mini Chat 入力行 | 54 |
| アイコン | 16(行内 13) |
| 最小クリック領域 | 28×28(ポインター操作) |

---

## 4. Corner radius

| Token | pt | 用途 |
|---|---|---|
| `radius.xs` | 4 | タグ、キーキャップ、チェックボックス |
| `radius.sm` | 6 | 小ボタン、セグメント内のつまみ |
| `radius.md` | 7 | 行、ボタン、フィールド |
| `radius.lg` | 8–9 | カード、コードブロック |
| `radius.xl` | 10 | パネル(サイドバー、コンテンツ)、Composer |
| `radius.window` | 12 | ウィンドウ、Mini Chat |

同心円ルール: 内側の角丸 = 外側の角丸 − 余白。例: ウィンドウ 12 − 余白 8 → パネル 10 前後(視覚的に揃える)。トグル(50%)以外で 12 を超える角丸は使わない。

---

## 5. Elevation & Material

| Level | 構成 |
|---|---|
| 0 Backdrop | 壁紙 + glow |
| 1 Pane | `surface.pane` + `stroke.edge` + 上辺 `stroke.highlight` + shadow `0 10 30 / .25` |
| 2 Well | `surface.well` + `stroke.edge`(影なし) |
| 3 Overlay | `surface.overlay` + `stroke.edge` + shadow `0 10 30 / .4` |
| 4 Floating (Mini) | `surface.mini` + blur 40 + shadow `0 30 80 / .55` |

SwiftUI への対応:
- Pane / Mini → `NSVisualEffectView(material: .hudWindow, blendingMode: .behindWindow)` に暗いティントを重ねる。macOS 26 以降は `.glassEffect(.regular.tint(...), in: .rect(cornerRadius: 10))` を優先する。
- Well → `Color.black.opacity(0.22)` と `.strokeBorder(.white.opacity(0.06))` の組み合わせ。

---

## 6. Component catalog

| Component | 仕様 | 状態 |
|---|---|---|
| **Sidebar Pane** | 幅 244、内側の余白 8。順に 信号機ボタン → 検索 ⌘K → ナビ(⌘1–5)→ 画面ごとのリスト → メモリメーター → Settings | — |
| **Nav Row** | 30h、アイコン 16、右端にショートカット(mono 10.5) | default / hover `white .05` / selected `accent.tint` |
| **List Row** | 30h、アイコン 13、タイトルは省略表示、右端にメタ情報(mono) | default / hover / selected `white .07` |
| **Section Label** | `label`、上 16 下 6 | — |
| **Model Selector** | 30h、ウェル型。名前 + `4bit · 32k`(mono) + 下向き矢印 | closed / open (overlay) |
| **Metrics Strip** | 30h のウェル。`182ms TTFT · 48.6 tok/s · 18.4 GB`。生成中は先頭に `live` ドット | idle / live |
| **TEMP Badge** | 18h、mono 10、`accent` の 35% 枠 | temp / (pinned 時は非表示) |
| **Pin Button** | 30h、アイコン + ラベル + ⌘P | unpinned / pinned(`accent.glass` の薄いティント) |
| **Message** | アバターなし。名前(`body` Semibold)+ mono のメタ情報 → 本文 `body.lg`。メッセージ間は 20 + グラデーションの区切り線 | complete / streaming(caret + `streaming…`) |
| **Code Block** | `surface.code`、radius 8、ヘッダー 30(言語 · ファイル名 · コピー) | — |
| **Composer** | 幅 740、radius 10。入力 → ツールバー(添付 · Preset · コンテキストメーター · Send ⌘↩) | idle / generating(上端リボン + Stop esc) |
| **Button** | 28h、radius 7、ラベル + キーキャップ。primary = `accent.glass`、default = ウェル、danger = 赤い枠 | hover / pressed / disabled(40%) |
| **Keycap** | 18h、radius 4、`white .07` | — |
| **Segmented** | ウェル + 2px の内側余白、選択部分 `white .09` | — |
| **Toggle** | 30×18 | off / on(`accent.glass.control`) |
| **Slider** | 4h のトラック + `live.gradient` + 14 のつまみ + 右側に mono の値 | — |
| **Field** | 28h、`black .28` | focus: `accent` の 2px リング |
| **Card / Well** | radius 9、`surface.well` | — |
| **KPI Tile** | ラベル → 値 `mono.lg` + 単位 → スパークライン 98×26 → 補足 mono | — |
| **Table** | ヘッダー `label`、行 38、数値は右揃えの mono、選択行は `accent .08` | — |
| **Progress** | 4h、`live.gradient` が流れる(1.4s) | — |
| **Diff Line** | 22h、旧/新の行番号 38+38、記号 16。左端 2px バー: 追加 `status.ok` / 削除 `status.error` | — |
| **Change Item** | チェックボックス 16 + 状態(M/A/D)+ ファイル名 + 増減行数 + 説明 | checked / unchecked / focused |
| **Warning Callout** | `status.warn` 5% 塗り + 18% 枠 + アイコン + トグル | — |
| **Mini Panel** | 幅 740、radius 12。入力行 54 → 区切り(生成中はリボン)→ 回答 → フッター 40(mono のメタ情報 + 操作キー) | idle / generating / answered |

アイコン: SF Symbols(Regular, scale small)。モックの線画アイコンは SF Symbols に置き換える(`bubble.left`, `folder`, `shippingbox`, `chart.bar`, `server.rack`, `gearshape`, `pin`, `key`, `arrow.up.left.and.arrow.down.right`)。

---

## 7. Animation

| 用途 | 値 | SwiftUI |
|---|---|---|
| hover / 選択 | 120ms ease-out | `.easeOut(duration: 0.12)` |
| パネル開閉(Inspector) | spring response 0.32, damping 0.86 | `.spring(response: 0.32, dampingFraction: 0.86)` |
| Mini Chat 表示 | 不透明度 0→1 + scale 0.98→1 で 180ms、回答部分は高さ方向に spring | `.spring(response: 0.28, dampingFraction: 0.9)` |
| Mini Chat 非表示 | 120ms ease-in、scale 0.99 | — |
| ストリーミング描画 | 30ms ごとにまとめて反映、行の追加は fade 80ms | `StreamBuffer` + `.transition(.opacity)` |
| 生成中リボン | 1px グラデーションが流れる、1.4s linear で繰り返し | `TimelineView(.animation)` |
| live ドット | 不透明度 .4↔1、1.2–1.6s | `.repeatForever(autoreverses: true)` |
| caret | 1s 間隔で点滅 | — |
| 数値の更新 | `contentTransition(.numericText())` 200ms | — |
| Diff の承認 | 承認した行はハイライトが 400ms で消え、ファイル一覧の M/A が ✓ に変わる | — |

視差効果を減らす設定(Reduce Motion)のとき: リボン・live ドット・caret は止めて静止表示にする。spring は 120ms のフェードに置き換える。
透明度を下げる設定(Reduce Transparency)のとき: ガラスを不透明な `#16171F` に置き換える。

---

## 8. Window layout

### Main Window
- 既定 1440×900、最小 1040×680。`.windowStyle(.hiddenTitleBar)` に、フルサイズのコンテンツビューを組み合わせる。
- 構成: `[ Sidebar 244 ] 8 [ Content flex ]`、外側の余白 8。
- 信号機ボタンは標準ボタンを非表示にし、同じ見た目(12pt、間隔 8)のボタンをサイドバーパネルの内側に描く。パネル左端から 12pt、上端から 10pt の位置に置く(角丸に沿うため、上を少し詰めると左右と上の余白が同じに見える)。マウスを乗せると ✕ − + を表示し、ウィンドウが非アクティブのときは灰色にする。
- Content の幅が 1100 未満になったら、サイドバーを自動で折りたたむ(⌃⌘S で切り替え)。
- Inspector(⌘I)は右側に 288 で開き、Content を押し縮める(重ねて表示はしない)。

| 画面 | Content 内のレイアウト |
|---|---|
| Chat | 読む幅 740 を中央に固定。Composer は下端に固定 |
| Work | `Files 232 │ Diff flex │ Assistant 340`、Diff の下端に承認バー 52 |
| Models | `List flex │ Details 320`。上から ストレージ → 表 → ダウンロード |
| Performance | KPI 4 列 → グラフ → 比較表 |
| API Server | 状態バナー(全幅)→ 2 列のグリッド 1.35 : 1 |
| Settings | 中央 760 のフォーム。グループ = 見出し `label` + カード |

### Mini Chat
- `NSPanel`(`.nonactivatingPanel`, `.floating`, `.fullSizeContentView`)、幅 740。
- 位置: 画面の上から 22%、水平中央。高さは内容に合わせて伸び、最大 520。
- 呼び出しは ⌥Space(変更可)。esc で閉じる。ピン留めしていなければ内容は破棄。⌘↩ でメインウィンドウの Chat に引き継ぐ。
- 最前面のアプリで選択中のテキストがあれば、Accessibility API で取得してコンテキストとして添付し、チップ(例: `Xcode · 24 lines`)で表示する。

---

## 9. Keyboard map

| Key | Action |
|---|---|
| ⌥Space | Mini Chat |
| ⌘K | コマンドパレット / 検索 |
| ⌘1–5 | Chat / Work / Models / Performance / API Server |
| ⌘, | Settings |
| ⌘N | 新しいチャット(一時) |
| ⌥1–3 | 空状態のおすすめプロンプトを実行 |
| ⌘P | ピン留めの切り替え |
| ⌘M | モデル切り替え |
| ⌘I | Inspector |
| ⌘↩ | 送信 / 変更を適用 / Mini → Chat |
| esc | 生成を止める / Mini を閉じる |
| ⌘⌫ | 変更提案をすべて却下 |
| ⌘R | ベンチマーク実行 |
| ⌥⌘T | 外観設定(透明感)を開く |
| ⌘. | API サーバー停止 |
