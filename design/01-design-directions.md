# Lay X — Design Directions (Phase 1)

Native AI. Beautifully local.

Status: **探索中 — 方向性の承認待ち**。本実装には未着手。
(Main Chat は Play で操作可能: Pin / New chat / 候補クリックで生成中 / Stop。Tweaks で conversation · generating · empty を切替)

---

## 3案の違い(色違いではなく構造の違い)

| | A — Quiet Native | B — Midnight Studio | C — Future Glass |
|---|---|---|---|
| 基本モード | Light(Dark派生) | Dark専用設計 | Dark + 壁紙透過 |
| ナビゲーション | 標準Sidebar(NavigationSplitView 2カラム) | Icon Rail + Chat List + Thread + Inspector の4カラム | ウィンドウから浮いたSidebar Island + 浮遊コントロール |
| モデル選択 | ツールバー左のポップアップ | Composer内のピル + Inspector | 画面上部中央の“Orb”カプセル |
| メッセージ | User=吹き出し / AI=本文そのまま(読み物) | ロール見出し付きの行(ログ的・高密度) | User=グラス色付きピル / AI=Orb付き本文 + グラスのコード |
| 計測値の扱い | メッセージ下に1行だけ | Inspectorで常時(TTFT/Prefill/Decode/メモリ/サンプリング) | メッセージ下のグラスチップ + Orbの呼吸 |
| Composer | 角丸16のカード(下部中央 720pt) | ドック型 + ツールバー行(モデル/System/温度/コンテキスト) | 高さ60のカプセル + グラデーションリング |
| 一時チャット表現 | 点線クロックの“Temporary”ピル + 脚注 | `TEMP`バッジ + 「Session · not saved」セクション | 「Now」セクション + “fades when you quit” |
| Mini Chat | Spotlight型: 1枚のフロストパネル、下部にキーキャップ付きアクション | Raycast型: フッターのActions ⌘K ポップオーバー、前面アプリの選択範囲を自動添付 | 入力カプセルと回答カードを分離。横に円形グラスボタン |
| 性格 | 落ち着き・可読性・純正感 | プロ向け・情報量・静かな高級感 | 体験性・奥行き・モーション |
| 主な技術 | `NavigationSplitView`, `.sidebar` Material | `HSplitView`相当の自作レイアウト, `.inspector()` | macOS 26 `.glassEffect()` / `GlassEffectContainer`, `NSPanel` |

## 各案のトークン(ドラフト)

### A — Quiet Native
- Accent `#2E63F6`(Lay Blue) / Text `#1D1D1F` / Secondary `#6E6E73` / Sidebar `#F4F3F1` / Canvas `#FFFFFF` / Code bg `#F7F7F9`
- Type: SF Pro Text 13(UI) · 14.5/25(本文) · 26 Semibold(空状態見出し) · SF Mono 12.5/20
- Radius: 7(行・ボタン) · 12(コード) · 16(Composer) · 18(吹き出し) · 20(Mini)
- 読み幅: 720pt 固定カラム

### B — Midnight Studio
- Base `#0B0B0E` / Panel `#0E0E11` / Raised `#131317` / Code `#07070A` / Hairline `rgba(255,255,255,.05)`
- Text `#EDEDF0` / Secondary `#9A9AA6` / Tertiary `#7C7C88` / Accent Indigo `#8B8BFF` / Success `#3DDC97`
- Type: Inter/SF 13(UI) · 14/24(本文) · 10.5 Uppercase +8%(セクション) · SF Mono 11–12.5(数値はすべて等幅 tabular)
- Radius: 5(バッジ) · 6–8(行・ボタン) · 10–12(カード・Composer) · 14(Mini)
- 密度: 行高 26–36pt、Inspector 288pt

### C — Future Glass
- Backdrop `#090A14` + 壁紙由来のIndigo/Teal光 / Glass `rgba(255,255,255,.065)` + blur 28 + 上辺ハイライト
- Text `#F2F3F8` / Secondary `#A9ACC2` / Accent Gradient `#7DE3FF → #A78BFA` / Live `#6EF2B4`
- Type: SF Pro Display 34 Semibold(挨拶) · 15/26(本文) · 13(UI)
- Radius: 12–14(行) · 18(コード) · 22(カプセル) · 24(Island) · 28–30(Composer・回答カード)
- Motion: Orbの呼吸(2.4s) · 生成中リボン(1.6s) · 回答カードはspringで下方向に展開

## 共通の原則(どの案でも維持)
- 一時チャットが既定。ピン留めだけが永続化 — 状態は常に画面上で見える
- キーボード優先: ⌥Space(Mini) / ⌘K / ⌘P(Pin) / ⌘↩(ウィンドウで開く) / ⌘M(モデル) / esc
- 数値は常に tabular figures。TTFT・tok/s はUIの装飾ではなく信頼の根拠として扱う
- 日本語と英語の混植で行間が崩れないよう本文は line-height 1.65–1.75

## 次のステップ(承認後)
1. 選ばれた方向(または組み合わせ)で残り5画面: Work(Diff承認) / Models / Performance / API Server / Settings
2. Design Tokens・Color・Typography・Spacing・Radius・Component Catalog・Animation・Window Layout の正式ドキュメント
3. Mock Data駆動の SwiftUI デザインプレビューアプリ(Xcodeプロジェクト)をこのフォルダに作成
