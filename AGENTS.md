# GPTPU Project — AGENTS.md

> **Version**: 0.1  
> **Last Updated**: 2026-07-29  
> **Target**: GPTPU Architecture Spec v0.1  
> **Language**: SystemVerilog (RTL), Python (simulator/toolchain)  

---

## 1. プロジェクト概要

本リポジトリは **GPTPU (General Purpose Tensor Processing Unit)** のRTL実装、シミュレータ、およびツールチェーンを開発するプロジェクトです。

GPTPUは以下の3つの設計思想を核としています：
1. **非同期セル・オートマトン的2D PEメッシュ** — GALS (Globally Asynchronous, Locally Synchronous)
2. **メモリ中心アーキテクチャ** — 各PEが512KB SRAMを主役とし、演算ユニットは"ぶら下がる"
3. **層ごとストリーミング** — 巨大モデルをオンチップSRAMだけで実行するためのDDRストリーミング

**エージェントは、上記の設計思想を一切損なわないことを最優先とする。**

---

## 2. リポジトリ構造

```
gptpu/
├── rtl/
│   ├── top/
│   │   └── gptpu_top.sv              # トップレベル: PEメッシュ + DDR I/O
│   ├── pe/
│   │   ├── pe_core.sv                # PEラッパ (SRAM + CCE + Router)
│   │   ├── coupled_compute_engine.sv # CCE: Vector/Scalar/Control
│   │   ├── sram_512kb.sv             # 4バンクSRAM (Bank0-3)
│   │   ├── vector_lane.sv            # 8-wide FP8 MAC + ALU
│   │   ├── scalar_ctrl.sv            # 16bit整数ALU + レジスタファイル
│   │   ├── configurable_lut.sv       # 16テーブル×256エントリ FP8 LUT
│   │   └── async_port_controller.sv  # L0/L1/L2非同期ポート制御
│   ├── noc/
│   │   ├── router_l0.sv              # 近傍層ルータ (8方向)
│   │   ├── router_l1.sv              # 高速道路層ルータ (4方向, 高速道路ノードのみ)
│   │   ├── router_l2.sv              # SN間層ルータ (境界高速道路ノードのみ)
│   │   ├── async_fifo_2stage.sv      # 2段非同期FIFO (Valid/Ready)
│   │   └── deadlock_free_arbiter.sv  # 次元順序ルーティング用アービタ
│   ├── io/
│   │   ├── ddr_controller.sv         # LPDDR5 PHY + Credit-Based FC
│   │   ├── stream_engine.sv          # STREAM.V / STREAM.S 命令ハンドラ
│   │   └── edge_io.sv                # グリッド境界のDDRインターフェース集約
│   └── common/
│       ├── gptpu_pkg.sv              # 共有パラメータ・型定数
│       ├── fp8_types.sv              # E4M3型定義と演算
│       └── async_handshake.sv        # Valid/Readyハンドシェイク基盤
├── sim/
│   ├── emulator/                     # サイクル精度エミュレータ (Python/C++)
│   ├── testbench/
│   │   ├── tb_pe_core.sv
│   │   ├── tb_router.sv
│   │   └── tb_top_moe_layer.sv       # MoE層推論統合テスト
│   └── stimuli/
│       └── deepseek_v4_flash_layer1.bin
├── toolchain/
│   ├── assembler/
│   │   └── asm.py                    # マイクロコードアセンブラ
│   ├── compiler/
│   │   └── onnx2gptpu.py             # ONNX→マイクロコード変換 (将来)
│   └── linker/
│       └── microcode_linker.py       # SN単位8KBマイクロコード配置
├── docs/
│   └── GPTPU_Architecture_Spec_v0.1.md
└── AGENTS.md                         # 本ファイル
```

### ディレクトリ追加ルール
- 新規モジュールは必ず上記のカテゴリ (`pe/`, `noc/`, `io/`, `common/`) のいずれかに配置する
- テストベンチは `sim/testbench/` に、テスト用バイナリは `sim/stimuli/` に配置する
- 共通の型・パラメータは `rtl/common/gptpu_pkg.sv` に集約し、各モジュールは `import gptpu_pkg::*;` する

---

## 3. アーキテクチャの核心思想（絶対に逸脱しないこと）

### 3.1 GALS (Globally Asynchronous, Locally Synchronous)
- **各PEは独立したローカルクロックを持つ**
- PE間通信は**非同期FIFO (2段) + Valid/Readyハンドシェイク**のみ
- グローバルクロックツリーや同期リセットは存在しない
- エージェントは「同期化のためにグローバルクロックを敷く」ような改変をしてはならない

### 3.2 メモリ中心 (Memory-Centric)
- **SRAMワイドライン → Vector ALU → SRAMワイドライン** の直接パスを維持
- 「レジスタファイル → ALU → レジスタファイル」の従来型パイプラインに戻してはならない
- Bank 0 (Matrix Tile) と Bank 1 (Activation/KV) は演算の主データパスとして扱う

### 3.3 距離適応型ルーティング
- ルーティングは**ハードウェア自律**（マイクロコードは dst_x, dst_y のみ指定）
- **次元順序ルーティング**: X方向を先に完全解決 → Y方向。これはデッドロック回避のため不変
- L1 (Expressway) は `(x%4==0 && y%4==0)` のPEのみ物理ポートを持つ

### 3.4 層ごとストリーミング
- 1層分のweights/KVブロックをDDRからSTREAMし、計算後に次層へ
- Credit-Based Flow Control でバックプレッシャーを実現
- オンチップSRAMに全weightsを置く設計に変更してはならない

---

## 4. コーディング規約

### 4.1 SystemVerilogスタイル
- **モジュール名**: スネークケース (`pe_core`, `async_fifo_2stage`)
- **パラメータ**: 大文字スネークケース (`PE_GRID_X`, `SRAM_BANK_SIZE`)
- **ポート**: `logic` を使用。非同期信号は `_valid`, `_ready` サフィックスを必ず付ける
- **クロック**: ローカルクロックは `clk_pe`, `clk_noc` などプレフィックスで区別
- **リセット**: 非同期アサート・同期デアサートのローカルリセット `rst_n` を各モジュールに持つ

### 4.2 非同期インターフェース標準
すべてのPE間通信は以下のインターフェースを使用する：

```systemverilog
typedef struct packed {
    logic [63:0] data;      // 8-wide FP8 = 64bit
    logic        valid;
    logic        ready;     // 相手からの入力
} noc_channel_t;
```

- `valid` は送信側がアサート
- `ready` は受信側がアサート
- データラッチは `valid && ready` のサイクルでのみ発生
- 2段FIFOは必ず `rtl/common/async_handshake.sv` のテンプレートを使用・拡張する

### 4.3 マイクロコード/ISA関連
- ISAは32bit固定長、39命令。命令追加は**仕様書セクション4を参照**の上、エンコーディング空間を確認すること
- 共有マイクロコードメモリ (SN単位8KB) のアドレス計算は `pe_id[3:0]` でオフセットを決定
- `SWAPL` 命令は1サイクルでActive/Shadow LUTを切り替える。グリッチフリーに実装すること

---

## 5. モジュール実装ガイドライン

### 5.1 PE Core (`pe_core.sv`)
**責務**: SRAMバンク、CCE、非同期ポートコントローラの接続とローカルクロック生成

**エージェント修正時の注意**:
- 4バンクSRAMは同時アクセス可能（Bankごに独立アドレスポート）
- Vector Laneは1サイクルで64B (SRAM 1ライン) を読み出し演算可能にする
- `async_port_controller` はL0を全PEが、L1/L2は高速道路ノード判定後にのみインスタンス化
- **L0ポートは方向ごとにフラット化**されたスカラ信号 (`l0_N_data/l0_N_valid/l0_N_ready`, `l0_N_in_*` 等)。ルータ内部ポート番号は [1]=N, [2]=E, [3]=S, [4]=W で、[0]=LOCAL と [5..7]=対角はPE内部で完結する
- **PE内部のルータ接続配列 (`router_pin_*`, `router_pout_*`) は必ず descending `[7:0]` 形式で宣言すること**。Verilator 5.032 は ascending `[8]` と descending `[7:0]` のunpacked配列ポート接続を要素順にフラット化するため、`port_in[7] <-> router_pin[0]` のようにインデックスが反転し、LOCAL/L1配送が破壊される（tb_top_l1 の配送バグの根本原因だった）
- **L1/L2ポートは方向別化済み**: `l1_{N,E,S,W}_{out,in}` (8本、out/data+valid+ready、in/data+valid+ready) と `l2_{E,W}_{out,in}` (4本)。`router_l1` と `router_l2` は **すべてのPEに無条件インスタンス化** し、非高速道路ノードではtopレベルで全入出力をtieする
- `is_boundary_node` = `is_highway_node && ((pe_x%SN_GRID_X==0 && pe_x!=0) || (pe_y%SN_GRID_Y==0 && pe_y!=0))`
- **iverilogは連続代入のgenerate内で配列ポート接続 (array slice) をサポートしない**ため、PE間配線は必ずスカラ方向信号にすること

### 5.3 ルータ (`router_l0.sv`, `router_l1.sv`, `router_l2.sv`)
**責務**: 距離適応型ルーティングとデッドロックフリー転送

**エージェント修正時の注意**:
- **絶対に次元順序ルーティングから外れないこと**: X方向の残りホップが0になるまでY方向転送を開始しない
- L1使用判定: `|dx| >= 4 || |dy| >= 4` かつ自PEが高速道路ノード `(x%4==0 && y%4==0)`
- **L1はtileベースで動作**: 高速道路ノードは自タイル (span 4) 内の配送をLOCALポートからL0へ再注入する。L1ポート並びは `[0]=N,[1]=E,[2]=S,[3]=W`。topレベルで高速道路ノード間リンクをstep 4でラティス配線する (AのE_out→BのW_in、BのW_out→AのE_in。方向は「相手の受け側」に入る点に注意)
- L2は境界高速道路ノードでのみ有効。`router_l2` は2ポート `[0]=E,[1]=W` のカットスルーで、SN境界 (x = SN_GRID_X, 2*SN_GRID_X, ...) を跨ぐ西/E東ノード対を専用リンクで接続する。高速道路間隔==SNサイズの構成ではL1と冗長になる

### 5.5 DDR/Streamエンジン (`ddr_controller.sv`, `stream_engine.sv`, `edge_io.sv`)
**責務**: LPDDR5 PHY制御、Credit-Basedフロー制御、層ごとストリーミング

**エージェント修正時の注意**:
- **キャッシュラインは128B (1024bit)固定、DDRバスは512bit幅。2ワード/ラインの組立/分解は `ddr_controller` が内包** (バス側)。`edge_io` は1024bit↔512bit×2の分解をPE側で担当する
- `ddr_controller` はトライステート `ddr_bus` + FSM (IDLE→ACTIVATE→TRCD_WAIT→READ/WRITE×2→PRECHARGE→TRP_WAIT) で駆動。req/respハンドシェイク
- `edge_io` は北端 (y=0) の各PE columnの64bit flitを集約して1024bitキャッシュライン化し、DDRへ。DDRからは1024bitを2×512bit SRAMラインへ分解
- `stream_engine` は STREAM.V(read)/STREAM.S(write) の命令デコードとDDRへの要求発行のみを担い、ライン転送のFIFO/組立は行わない
- CreditはPEのSRAM空き容量から生成。Credit=0で自動停止（バックプレッシャー）

---

## 6. テスト方針

### 6.1 ユニットテスト（必須）
各モジュール修正後、以下のテストベンチをパスさせる：

| テストベンチ | 検証内容 |
|-------------|---------|
| `tb_pe_core.sv` | 基本算術 (VMAC/VADD)、LUT参照、分岐、SRAMバンク競合、L1/L2ポート接続 |
| `tb_router.sv` | 8方向同時通信、L1高速道路到達、デッドロックフリー確認 |
| `tb_l1.sv` | router_l1 tileベースルーティング (オフロード/配送) |
| `tb_async_fifo.sv` | 非同期クロックドメイン跨ぎデータ転送、メタスタビリティ |
| `tb_lut_swap.sv` | SWAPL命令の1サイクル切り替え、グリッチチェック |
| `tb_lut.sv` | LUT bootロードとtop-level write経路 |
| `tb_ddr.sv` | ddr_controller + ビヘイビアDDRモデルのround-trip |
| `tb_stream.sv` | STREAM.V/S命令のreq/resp発行 |
| `tb_edge.sv` | edge_ioの北端集約と1024↔512分解 |
| `tb_pipeline.sv` | DDR↔PEフル結合データパスround-trip |
| `tb_top_moe_layer.sv` | MoE層トップ統合（スモーク） |
| `tb_top_l1.sv` | L1エクスプレスウェイ統合テスト（T1 E-W / T2 N-S / T3 L0のみ。`make top_l1` で実行、PASS） |

### 6.2 統合テスト（目標）
- **Conway's Life**: 最小グリッド (8x8) でCAシミュレーション。近傍通信とLUT[15]の動作確認
- **Dense DNNレイヤ**: 64PEでMLP 1層。BCAST + VMACのデータフロー確認
- **MoE FFN層**: Expert重みのタイル分散、非同期dispatch、層ごとSTREAMの連携

### 6.3 シミュレータ連携
- `sim/emulator/` はサイクル精度エミュレータ。RTLと同じメモリマップ・ISAを持つ
- エミュレータとRTLの結果不一致が発生した場合、**RTLを修正する前に仕様の解釈を再確認**すること
- **検証ツール**: シミュレーション検証は **Verilator主軸**。iverilog 12はunpacked配列書き込みが`x`になるバグがあるため**構造コンパイル/lint専用**
- 全TBは `make -C sim unit` で一括実行 (MakefileにVerilatorビルド定義あり)

---

## 7. エージェント作業ガイドライン

### 7.1 実装優先順位（Roadmap）
エージェントは依頼に応じて以下の優先順位で作業する：

1. **Phase 0: 基盤** — `gptpu_pkg.sv`, `async_handshake.sv`, `async_fifo_2stage.sv`
2. **Phase 1: PE内部** — `sram_512kb.sv`, `vector_lane.sv`, `scalar_ctrl.sv`, `configurable_lut.sv`
3. **Phase 2: CCE** — `coupled_compute_engine.sv`, マイクロコードデコーダ
4. **Phase 3: 通信** — `router_l0.sv`, `async_port_controller.sv`, `pe_core.sv`
5. **Phase 4: 高速道路** — `router_l1.sv`, `router_l2.sv`
6. **Phase 5: I/O** — `ddr_controller.sv`, `stream_engine.sv`, `gptpu_top.sv`
7. **Phase 6: ツールチェーン** — アセンブラ、エミュレータ、コンパイラ

### 7.2 修正・追加の判断基準
- **新しい演算を追加したい**: まずISAの空きオペコードを確認。Vector/Salarのどちらに属するか判断
- **通信を高速化したい**: ルーティングアルゴリズムの変更ではなく、FIFO深度やL1/L2の利用率改善を先に検討
- **メモリ容量を増やしたい**: SKU別パラメータ (`GPTPU_S`, `GPTPU_M` 等) を `gptpu_pkg.sv` に追加し、ファブ時選択を想定
- **新しい活性化関数を追加したい**: LUTテーブル (9-15) の初期化データを変更。ハードウェア変更は不要

### 7.3 禁止事項
以下の行為はアーキテクチャの根本を破壊するため、**エージェントは実行してはならない**：
- グローバルクロックの導入や同期化
- PE間通信をValid/Ready以外の方式（例: AXI, Credit直結）に変更
- 次元順序ルーティングの放棄（デッドロック原因）
- SRAMを小容量レジスタファイルに置き換える
- 全weightsをオンチップに置く設計変更

### 7.4 ドキュメント更新義務
- RTLに新規パラメータやポートを追加した場合、`docs/` 以下の仕様書ではなく **本AGENTS.mdの「モジュール実装ガイドライン」セクション** を更新する
- ISA変更が発生した場合、必ず `toolchain/assembler/asm.py` の命令テーブルも同時に更新すること

---

## 8. 定数・パラメータリファレンス

```systemverilog
// rtl/common/gptpu_pkg.sv (推奨パラメータ)
localparam int PE_GRID_X = 16;          // GPTPU-M想定
localparam int PE_GRID_Y = 8;
localparam int SRAM_BANK0_SIZE = 256*1024;  // 256KB
localparam int SRAM_BANK1_SIZE = 128*1024;  // 128KB
localparam int SRAM_BANK2_SIZE = 64*1024;   // 64KB (LUT含む)
localparam int SRAM_BANK3_SIZE = 64*1024;   // 64KB
localparam int VECTOR_LANE_WIDTH = 8;   // 8-wide FP8
localparam int FP8_E4M3_WIDTH = 8;
localparam int MICROCODE_SIZE = 8192;   // 8KB per SN
localparam int LUT_TABLES = 16;
localparam int LUT_ENTRIES = 256;
localparam int LUT_ENTRY_WIDTH = 8;     // FP8
```

---

## 9. トラブルシューティング・FAQ

**Q: 非同期FIFOのメタスタビリティが心配です**  
A: 2段シンクロナイザは必須。`async_handshake.sv` のテンプレートを使用し、セットアップ/ホールド違反はCDC (Clock Domain Crossing) チェックツールで検証する。

**Q: LUTのShadow切り替えでデータ競合が起きそうです**  
A: `SWAPL` はCCEのデコードステージで単なるセレクタ切り替えとして実装。LUTアクセスパイプラインに影響を与えない設計にする。

**Q: MoEのExpertランダムアクセスで帯域が不足します**  
A: RTLではなく、DDRプリフェッチ戦略 (`io/ddr_controller.sv` の投機読み出しロジック) を改善する。RTLの基本構造は変更しない。

**Q: 面積見積もり (165mm²) が目標を超えています**  
A: プロセスノードやSRAMマクロの見積もり問題。RTLの構造変更ではなく、`docs/` の仕様書の「今後の課題」に記載された「3nmプロセスでの再見積もり」を参照。

---

## 10. 外部参照

- `docs/GPTPU_Architecture_Spec_v0.1.md` — アーキテクチャ仕様書（設計思想の詳細）
- `rtl/common/gptpu_pkg.sv` — SystemVerilog型・パラメータ定義（実装の真実ソース）
- `toolchain/assembler/asm.py` — ISAエンコーディングの真実ソース

---

*AGENTS.mdは、GPTPUの設計思想を維持しつつ、複数のエージェントが並行して実装・修正できるよう作成されています。*
