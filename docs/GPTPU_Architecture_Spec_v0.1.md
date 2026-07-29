# GPTPU (General Purpose Tensor Processing Unit)
## アーキテクチャ仕様書 v0.1

---

## 1. 概要

GPTPUは、非同期・セル・オートマトン（Cellular Automaton）的な2D PEメッシュを基盤とする、汎用行列演算アクセラレータである。従来のグローバルクロック駆動型システィックアレイとは異なり、各Processing Element（PE）は独立したローカルクロック（GALS: Globally Asynchronous, Locally Synchronous）で動作し、近傍8方向の非同期ハンドシェイク（Valid/Ready）により通信を行う。

本アーキテクチャは、Transformer/MoE LLM、CNN、Dense DNN、および純粋なセル・オートマトンシミュレーションを同一ハードウェア上で実行することを目標とする。特にMoE（Mixture-of-Experts）モデルの極端なスパース性（13B活性/284B総パラメータなど）を、「必要なセルのみが起動する」非同期性によって電力効率よく処理する点に強みを持つ。

---

## 2. トップレベルアーキテクチャ

### 2.1 グリッド構成

GPTPUは、2Dメッシュ上に配置された同一PEから構成される。基本構成は以下の通り。

| 構成 | PE数 | SRAM合計 | 想定ダイ面積 | ターゲット |
|------|------|----------|-------------|-----------|
| GPTPU-S | 64 (8×8) | 32 MB | ~25 mm² | 軽量モバイル |
| GPTPU-M | 128 (16×8) | 64 MB | ~50 mm² | 標準モバイル/ノートPC |
| GPTPU-L | 256 (16×16) | 128 MB | ~100 mm² | ハイエンドモバイル |
| GPTPU-XL | 512 (32×16) | 256 MB | ~200 mm² | デスクトップ/エッジ |

同一ISA・同一PE設計を維持し、ファブ時のメタルマスクまたはフューズでPE数/SRAMサイズを選択する。ソフトウェア互換性は100%保持される。

### 2.2 階層通信ネットワーク

PE間通信は3層の非同期ネットワークにより実現される。

#### Layer 0: 近傍層（Neighborhood）
- **全PEが所持**
- 8方向（N, S, E, W, NE, NW, SE, SW）
- 1ステップ先のPEとの直接接続
- 2段FIFO（Valid/Readyハンドシェイク）
- 主用途: 行列タイルのシスティック流動、KVスライスの隣接アクセス、CAの近傍状態読み出し

#### Layer 1: 高速道路層（Expressway）
- **高速道路ノードのみ所持**: 座標が (x%4==0 && y%4==0) のPEのみ
- 4方向（N4, S4, E4, W4）
- 4ステップ先の高速道路ノードへ直接到達
- グリッド全体の水平/垂直移動を短縮（32×32グリッドで最大ホップ数を31→8に削減）
- 非高速道路PEは物理的にL1ポートを持たず、面積・消費電力を削減

#### Layer 2: SN間層（Super-Node）
- **境界高速道路ノードのみ有効**
- Super-Node（4×4 PE）間の接続
- 隣接SNの高速道路ノード間で直接通信

### 2.3 ルーティング

ルーティングは各PEの非同期ルータが自律的に実行する。マイクロコードは宛先座標 (dst_x, dst_y) のみを指定し、経路選択はハードウェアに委ねられる。

**距離適応型ルーティング:**
1. 高速道路ノードかつ |dx|≥4 or |dy|≥4 の場合、L1を優先
2. 非高速道路PEの場合、最寄り高速道路ノードへL0で移動
3. 最終調整はL0で実行

**デッドロック回避:** 次元順序ルーティング（X方向を先に完全解決し、その後Y方向）により、循環待ちを防止。

---

## 3. Processing Element (PE)

### 3.1 設計思想: "メモリが主、プロセッサが従"

各PEは1つの大容量SRAM（512KB）を主役とし、演算ユニットはそのSRAMに"ぶら下がる"形で配置される。従来の「レジスタ→ALU→レジスタ」のサイクルではなく、「SRAMワイドライン→Vector ALU→SRAMワイドライン」の直接パスを持つ。

### 3.2 SRAM構成

512KB SRAMは4バンクに分割される。

| Bank | サイズ | 用途 |
|------|--------|------|
| Bank 0 | 256 KB | Matrix Tile Buffer（行列タイル、Expert重みスクラッチ） |
| Bank 1 | 128 KB | Activation / KV Slice（入出力アクティベーション、KVキャッシュスライス） |
| Bank 2 | 64 KB | Configurable LUT + 設定レジスタ |
| Bank 3 | 64 KB | I/O Buffer + Microcode + 通信FIFO |

### 3.3 Coupled Compute Engine (CCE)

#### 3.3.1 共有マイクロコード
- Super-Node（4×4 = 16 PE）単位で8KBのマイクロコードメモリを共有
- 各PEは独立したPCを持ち、MIMD的に実行可能
- PEあたりの物理メモリは512B相当（面積効率）

#### 3.3.2 Vector Lane
- 8-wide FP8（E4M3）MAC
- 並列演算: ADD, SUB, MUL, MAX, MIN
- 1サイクルでSRAMの64Bラインを読み出して演算可能

#### 3.3.3 Scalar Control
- 16bit整数ALU（アドレス計算、分岐判定）
- レジスタファイル: 16 words × 32bit
- ループカウンタ、ステータスレジスタ

#### 3.3.4 Configurable LUT
- Bank 2の先頭32KBに配置
- 16テーブル × 256エントリ × FP8
- テーブルID: 4bit (0-15)
- Active / Shadow の2バンク構成。SWAPL命令で1サイクルで切替
- 初期テーブル（Boot ROMからロード）:
  - 0: Tanh（固定）
  - 1: Exp（固定）
  - 2: 1/√x（固定）
  - 3: 1/x（固定）
  - 4: Sin（固定）
  - 5: Cos（固定）
  - 6: SiLU（カスタム初期化）
  - 7: Sigmoid（カスタム初期化）
  - 8: GELU（カスタム初期化）
  - 9-15: User Defined（アプリケーション固有）

### 3.4 Async Port Controller

| 層 | ポート数 | 所持PE |
|----|---------|--------|
| L0 | 8 | 全PE |
| L1 | 4 | 高速道路ノードのみ |
| L2 | 4 | 境界高速道路ノードのみ |

各ポートは2段FIFO + Valid/Readyハンドシェイク。

---

## 4. 命令セットアーキテクチャ (ISA)

32bit固定長、3アドレス形式。39命令。

### 4.1 レジスタ構成

| レジスタ | 数 | 用途 |
|---------|-----|------|
| V0-V15 | 16 | ベクトルレジスタ（8-wide FP8） |
| R0-R15 | 16 | スカラレジスタ（16bit） |
| PC | 1 | プログラムカウンタ |
| LC | 1 | ループカウンタ（暗黙的） |
| STATUS | 1 | Valid/Readyフラグ、ゼロフラグ |

### 4.2 命令一覧

#### A. データ移動 (8命令)
| 命令 | 動作 |
|------|------|
| LDV Vd, Ba, off(Rs) | Vd = SRAM[Bank a][off + Rs] |
| STV Vs, Ba, off(Rs) | SRAM[Bank a][off + Rs] = Vs |
| MOV Vd, Vs | Vd = Vs |
| MOVI Rd, imm | Rd = imm（10bit符号付き） |
| MOVIS Rd, Rs | Rd = Rs |
| V2R Rd, Vs, lane | Rd = Vs[lane] |
| R2V Vd, Rs, lane | Vd[lane] = Rs |
| DUP Vd, Rs | Vd = {Rs, Rs, ..., Rs} |

#### B. ベクトル演算 (9命令)
| 命令 | 動作 |
|------|------|
| VMAC Vd, Va, Vb, Vc | Vd = Va * Vb + Vc |
| VADD Vd, Va, Vb | Vd = Va + Vb |
| VSUB Vd, Va, Vb | Vd = Va - Vb |
| VMUL Vd, Va, Vb | Vd = Va * Vb |
| VMAX Vd, Va, Vb | Vd = max(Va, Vb) |
| VMIN Vd, Va, Vb | Vd = min(Va, Vb) |
| LUT Vd, tid, Vs | Vd = ActiveLUT[tid][Vs] |
| VSF Vd, Va | Vd = shift(Va) |
| BCAST Vs, mode, Rx | ブロードキャスト (ROW/COL/ALL) |

#### C. スカラー演算 (8命令)
| 命令 | 動作 |
|------|------|
| ADD Rd, Ra, Rb | Rd = Ra + Rb |
| SUB Rd, Ra, Rb | Rd = Ra - Rb |
| MUL Rd, Ra, Rb | Rd = Ra * Rb（下位16bit） |
| AND Rd, Ra, Rb | Rd = Ra & Rb |
| OR Rd, Ra, Rb | Rd = Ra \| Rb |
| XOR Rd, Ra, Rb | Rd = Ra ^ Rb |
| SHL Rd, Ra, imm | Rd = Ra << imm |
| SHR Rd, Ra, imm | Rd = Ra >> imm |

#### D. 通信 (4命令)
| 命令 | 動作 |
|------|------|
| SEND Vs, Rx, Ry | Vsを座標(Rx, Ry)へ非同期送信 |
| RECV Vd, Rx, Ry | 座標(Rx, Ry)から受信待ち |
| RECV Vd, ANY | 任意PEから受信待ち |
| TEST Rd, PORT | Rd = PORT状態 |

#### E. 制御 (8命令)
| 命令 | 動作 |
|------|------|
| JMP off | PC += off |
| BRZ Rd, off | Rd==0 なら PC += off |
| BNZ Rd, off | Rd!=0 なら PC += off |
| BVALID PORT, off | PORTにValidなら PC += off |
| BREADY PORT, off | PORTがReadyなら PC += off |
| DJNZ Rd, off | Rd--, Rd!=0 なら PC += off |
| SWAPL | ActiveLUT ↔ ShadowLUT |
| NOP | 1サイクル待機 |

#### F. ストリーミング (2命令)
| 命令 | 動作 |
|------|------|
| STREAM.V Vd, ext_addr, Rlen | 外部DDR→SRAMへベクトルストリーム読み出し |
| STREAM.S ext_addr, Vs, Rlen | SRAM→外部DDRへベクトルストリーム書き込み |

---

## 5. メモリモデルとストリーミング

### 5.1 層ごとストリーミング

GPTPUは、巨大モデルの全weightsをオンチップに保持しない。代わりに、**層（Layer）ごとに必要なweightsとKV CacheブロックをDDRからストリーミング**し、計算が終われば次の層のデータを読み込む。

この方式により、64MBオンチップSRAMでも284B総パラメータのMoEモデル（例: DeepSeek V4-Flash）を実行可能となる。

### 5.2 DDRインターフェース

- LPDDR5-6400、2ch〜4ch
- 実効帯域: 70-100 GB/s
- キャッシュライン: 128B（Vector Lane幅に合わせる）
- Credit-Based Flow Controlにより輻輳を防止

### 5.3 ストリーミングプロトコル

```
PEのSRAM空き容量 → Credit生成 → エッジI/Oへ送信
エッジI/OはCredit>0の間のみDDRからデータをバースト転送
Credit=0で自動停止（バックプレッシャー）
```

### 5.4 帯域見積もり（DeepSeek V4-Flashクラス）

1層あたりのweights読み出し（FP4）:
- Top-6 Routed Experts: 6 × 12MB = 72MB
- Shared Expert: 12MB
- Attention weights: ~20-30MB
- 合計: ~100-110MB/層

43層 × 110MB = 4.7 GB/トークン
LPDDR5 2ch（~75GB/s）で理論値: ~16ms/トークン → **60 tok/s**（理想値）
Expertランダムアクセスペナルティを考慮すると、実効 **5-15 tok/s**

### 5.5 KV Cache扱い

CSA/HCA圧縮により、1M contextのKV CacheはV3.2比で7%（約3GB）。64MBオンチップSRAMでは全保持不可。

- 層ごとに必要な圧縮KVブロック（~400KB/層）のみSTREAM
- 新規KVは計算後、DDRへ追記
- オンチップで保持可能なのは約16K-32K tokens分

---

## 6. ワークロード適合性

### 6.1 MoE LLM（例: DeepSeek V4-Flash）

| 処理 | 評価 | 詳細 |
|------|------|------|
| MoE FFN | ◎ | 1 Expert = 16タイル（1024×512）。8PEで時間分割実行。非同期dispatchで必要PEのみ起動 |
| CSA Attention | ○ | FP4 indexer dot productはLUT+MACで実行。KVブロックは層ごとSTREAM |
| RMSNorm/RoPE | ◎ | 1/√x, Sin, CosをLUTで1サイクル実行 |
| SwiGLU | ◎ | SiLUはカスタムLUT。ClampはVMIN/VMAX |

**結論**: 64MB SRAM + LPDDR5で実行可能。応答速度は帯域依存だが、モバイルでの中短コンテキスト推論に実用的。

### 6.2 CNN

畳み込みはim2colで行列積に帰着。各PEがローカルフィルタタイルと入力パッチをSRAMに保持し、8-wide MACで積和演算。

- ReLU/LeakyReLU: LUTカスタムテーブル
- MaxPooling: VMAX命令
- Halo Exchange: L0近傍通信で自然に実現

### 6.3 Dense DNN / MLP

最も得意なワークロード。重みタイルを各PEに分散し、入力ベクトルをBCASTで一斉配信。決定的なデータフローにより、理論ピークの70-80%が達成可能。

### 6.4 セル・オートマトン

各PEが「セル」として自律動作。近傍8方向の状態をRECVし、LUT[15]にロードしたルールテーブルで次状態を計算し、SENDで結果を周囲へ伝播。Conway's Lifeなどは数命令で記述可能。

---

## 7. 消費電力と面積

### 7.1 面積見積もり（GPTPU-M: 128PE/64MB @ N3E）

| ブロック | 面積 | 備考 |
|----------|------|------|
| SRAM (64MB) | ~130 mm² | 高密度6T SRAMマクロ |
| PEロジック (128個) | ~20 mm² | CCE + Router + RegFile |
| DDR I/O + PHY | ~8 mm² | LPDDR5 2ch |
| クロック/PLL/制御 | ~5 mm² | GALSクロック生成 |
| **合計** | **~165 mm²** | 目標50mm²より大きい → 5nm世代 or 256PE/128MB版で再配分 |

※ 3nmプロセスでは、SRAM密度向上により ~100mm²以下に収まる見込み。

### 7.2 消費電力見積もり（GPTPU-M @ 500MHz）

| モード | 消費電力 | 詳細 |
|--------|---------|------|
| アイドル | 10-20 mW | 全PE SRAMリテンション + クロック停止 |
| 軽負荷 (32PE活性) | 0.5-1 W | 一部PEのみ動作 |
| 中負荷 (64PE活性) | 1.5-2.5 W | 3B級Denseモデル推論 |
| フル負荷 (128PE活性) | 4-6 W | MoE層実行時ピーク |

---

## 8. スケーラビリティと製品展開

| SKU | PE数 | SRAM | 想定用途 |
|-----|------|------|----------|
| GPTPU-S | 64 (8×8) | 32 MB | スマートウォッチ、IoT |
| GPTPU-M | 128 (16×8) | 64 MB | スマートフォン、タブレット |
| GPTPU-L | 256 (16×16) | 128 MB | ハイエンドスマホ、ノートPC |
| GPTPU-XL | 512 (32×16) | 256 MB | デスクトップ、エッジサーバー |

同一ISA、同一ダイ設計（フューズ/マスクでPE数/SRAMサイズ選択）。ソフトウェアは全SKUでバイナリ互換。

---

## 9. 今後の課題

1. **RTL実装とタイミング閉塞**: 非同期FIFOと高速道路の長距離配線
2. **コンパイラ/アセンブラ**: 高級言語（Python/ONNX）からマイクロコードへの変換
3. **シミュレータ開発**: サイクル精度エミュレータによる性能検証
4. **DDRプリフェッチ戦略**: Top-6 Expert選択と並行した投機的先読み
5. **電力管理**: さらなる細粒度パワーゲーティング（未使用Bankの電源遮断）

---

## 10. まとめ

GPTPUは、「非同期セル・オートマトン + 大容量SRAM + 層ごとストリーミング」という3つの設計思想により、以下を同時に実現する。

- **巨大MoEモデルのモバイル実行**（層ごとDDRストリーミング）
- **極めて高い電力効率**（スパース時は不要なPEを完全停止）
- **CNN/DNN/CAへの汎用性**（Configurable LUT + 共有マイクロコード）
- **低コスト・高歩留まり**（同一設計でのSKU展開、GALSによるタイミング緩和）

これは「クラウド専用だった巨大AIを、個人のデバイスに解放する」ための基盤技術となる。

---

*Document Version: 0.1*  
*Date: 2026-07-29*  
*Status: Architecture Preview*
