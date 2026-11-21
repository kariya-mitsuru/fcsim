# 段階 3 以降の進め方（検討資料）

段階 2 までで、仮想 FC ファブリックとしての基本（ログイン・I/O・EH・障害注入・RSCN・multipath 連携）は揃った。
`docs/design.md` の段階 3 には「ゾーニング、NPIV、fc_host 統計、rtslib upstream、initiator 側 CLI」を挙げていたが、
これらは規模も性質もばらばらなので、価値・規模・依存関係を整理し、進める順序を提案する。

## 1. 現状

- カーネルモジュール `tcm_fcsim`（約 2,900 行）。開発用カーネル 6.18 + virtme-ng でのみビルド・検証している
- 設定手段: target 側は targetcli（ラッパー経由）、initiator 側・ファブリックは configfs を直接操作
- テスト 9 本（`make test`）。KASAN / lockdep 有効で全 PASS
- 使える標準ツールとの連携は確認済み: targetcli / targetctl、multipathd（ALUA）、sg3_utils、FC netlink イベント

## 2. 候補の一覧

元の 5 項目に、検討の過程で出てきた 3 項目（F〜H）を加えた。

| | 候補 | 得られるもの | 規模 | リスク | 依存 |
|---|---|---|---|---|---|
| A | initiator 側 CLI（`fcsimctl`） | 手作業の configfs 操作が不要になる。状態の一覧表示、設定の保存・復元 | 小 | 低 | なし |
| B | fc_host 統計 | `/sys/class/fc_host/hostN/statistics/*` が実機同様に動く。監視ツールで観測できる | 小 | 低 | なし |
| C | ゾーニング | 「どの initiator からどの target が見えるか」をスイッチ側で制御（LUN マスキングとの 2 層） | 中 | 中 | A（操作性） |
| D | NPIV | 1 つの物理ポート上に仮想ポート（`vport_create`）。VM ごとの WWPN、ポートごとのゾーニング・マスキング | 大 | 中〜高 | C（意味を持たせるには）、A |
| E | rtslib upstream | ラッパー無しで素の targetcli から使える | 小（作業）〜大（調整） | 高（受け入れられない可能性） | カーネル upstream の判断 |
| F | 配布・カーネル互換（追加） | 開発用カーネル以外（WSL2、RHEL/Alma 9・10 等）で実際に使える | 中 | 中 | 利用環境の決定 |
| G | FPIN / marginal パス（追加） | 障害注入の拡張。リンク品質劣化の通知で rport が Marginal になり、multipathd がそれに反応する | 小〜中 | 低 | なし |
| H | FC BSG（ELS/CT パススルー）（追加） | ネームサーバ問い合わせ等、HBA 管理ツール向けの低レベル操作 | 中 | 中 | なし |

## 3. 各候補の検討

### A. initiator 側 CLI（`fcsimctl`）

これまでの設計方針（カーネルは仕組み、ポリシーはユーザ空間）のうち、まだ無かった「ユーザ空間側」に当たる。
ゾーニングや障害シナリオの操作面もここに載るので、他の候補の土台になる。

- 形態: targetcli と同じく Python 3。追加依存なしの単一スクリプトを `tools/` に置く
- 機能
  - `status`: ファブリック全体の一覧。host（link・port_id）、ログイン済み target、rport の状態、見えている sd デバイス、障害ルール
  - `host create|delete <wwpn>`、`link <wwpn> up|down`
  - `fault set <initiator> <target|any> key=value...`、`fault clear`
  - `save|restore <file.json>`: host・link・障害ルール（後にゾーン）を JSON で保存・復元。
    target 側は従来どおり `targetctl save/restore`（復元は target 側が先）
- テスト: `tests/cli-fcsim.sh`（作成 → status → save → 全削除 → restore → 一致確認）
- 後で足せるもの: シナリオ実行（「パス X を N 秒ごとに上げ下げ」等）、起動時復元の systemd unit（F の配布と合わせて）

### B. fc_host 統計

`get_fc_host_stats` / `reset_fc_host_stats` を実装すると、FC transport が `statistics/` 配下の属性を出す。

- 数える値（iport ごとに per-CPU カウンタ。ホットパスでロックを取らない）
  - `fcp_input_requests` / `fcp_output_requests` / `fcp_control_requests`、`fcp_input_megabytes` / `fcp_output_megabytes`
  - `tx_frames` / `rx_frames` / `tx_words` / `rx_words`（データ長をフレームサイズ 2048 で割った値と、コマンド・応答の各 1 フレームから換算）
  - `link_failure_count`（link down）、`lip_count`（issue_lip）、`fcp_packet_aborts`（EH の abort）、
    `dumped_frames`（障害注入による破棄）、`seconds_since_last_reset`
- 実機と同じパスに出るので、例えば Prometheus node_exporter の fibrechannel collector がそのまま読める
- テスト: I/O 量と統計の増分の突き合わせ、reset

### C. ゾーニング

スイッチ側のアクセス制御。LIO の ACL（target 側の LUN マスキング）とは別の層で、ここで許可されない組はログイン自体が起きない。

- モデル（WWN ゾーニングの基本形）
  - ファブリックは 1 つ、有効なゾーン構成も 1 つ
  - ゾーン = メンバー WWPN の集合。initiator と target が同じゾーンに入っていればログインできる
  - `mode`: `off`（既定、現在と同じ全対全）／`on`（ゾーンで許可された組だけ）
- 変更の適用方式は、即時反映（単純だが、複数ゾーンの変更が途中状態を経由する）と、
  ステージングして commit（実機の cfgsave / cfgenable に相当）を比べ、後者に決めた

**決定（§5 の 3）: ステージングして commit で一括反映する。** configfs の形は次の案で進める。

```
/sys/kernel/config/fcsim/
  zoning/
    mode       off | on        編集用（commit で反映）
    commit     (wo) 1 を書くと、編集中の構成（mode と zones/）をまとめて有効にする
    pending    (ro) 1: 編集中の構成が有効な構成と違う
    active     (ro) 有効な構成の一覧（mode と、ゾーンごとのメンバー）
  zones/<name>/
    members    編集用。WWPN を 1 行 1 つ（書き込みで全置換）
```

- 編集（mkdir / rmdir / `members` / `mode` への書き込み）はファブリックに一切影響しない。
  `commit` の時点で有効な構成のコピーを作って差し替え、reconcile を 1 回だけ走らせる。
  途中状態を経由しないので、パスが一時的に消えるといった副作用がない
- 編集の取り消し（revert）は configfs では作らない（利用者が作ったディレクトリをカーネルから消せないため）。
  CLI 側で「有効な構成に合わせて zones/ を作り直す」操作として用意する
- CLI の `save` / `restore` は編集用の構成を保存・復元し、`restore` の最後に commit する
- reconcile への影響: 「あるべき nexus」の条件に、有効な構成でのゾーン判定を加えるだけ。
  ゾーン変更で外れた組はログアウトし（rport の dev_loss 開始）、入った組はログインする。
  実機のスイッチと同様、影響を受けたポートに RSCN を送る
- テスト: 2 × 2 構成で、ゾーンの付け外しに応じて rport とパス数が変わること。multipathd のパス数の追従

### D. NPIV

物理ポート（iport）の上に仮想ポートを作る。実機では VM ごとに WWPN を割り当てる用途で使われる。

- 作成は標準の口を使う: `echo <wwpn>:<wwnn> > /sys/class/fc_host/hostN/vport_create`。
  FC transport が `vport_create` を呼ぶので、そこで `fc_vport` を親とする新しい Scsi_Host（= iport）を作る。
  `vport_delete` / `vport_disable` も実装し、物理ポートの `max_npiv_vports` と `npiv_vports_inuse` を出す
- ファブリック上は独立したポート: 自分の port_id と WWPN でログインし、ゾーニングと ACL も個別に効く。
  物理ポートの link down で配下の vport も down になる
- 決める必要があること（§5）: vport を configfs にどう見せるか
  - sysfs からだけ作れて、configfs には出さない（障害注入や link は物理ポート単位）
  - configfs にも出し、vport 単位で障害注入できるようにする。
    `configfs_register_group` を使えばカーネル側から作った vport を見せられるが、寿命管理が複雑になる
- 規模が大きい理由: Scsi_Host の親子関係、削除の順序（`fc_vport_terminate`）、物理ポートとの連動、
  既存の iport コードの共通化
- テスト: sysfs からの作成・削除、vport の WWPN での ACL とゾーニング、物理ポートの link down の伝搬、
  vport をまたいだ multipath

### E. rtslib upstream

- rtslib-fb の fabric 一覧には、カーネル本体（in-tree）にある fabric module だけが載っている。
  out-of-tree の fcsim を先に提案しても受け入れられる見込みは低い
- つまりカーネルの upstream 投稿をするかどうかが先決（§5）。しないなら、ラッパー方式を続けて配布物（F）に同梱するのが現実的
- 投稿を目指す場合は、upstream の SCSI / target メンテナの流儀に合わせたコード整理、モジュール名やインタフェースの見直し、
  kselftest 等への移植が必要。別の大きな作業になる

**決定（§5 の 2）: カーネル upstream は目指さない。したがって E も行わない。**

- out-of-tree モジュールとして配布する（F の DKMS RPM / WSL2 向け手順）
- targetcli 連携は今のラッパー方式（`tools/fcsim-targetcli` / `fcsim-targetctl`）を続け、配布物に同梱する
- configfs の配置や属性名は、使いながら見直してよい（変更したら `docs/design.md` と CLI を合わせて更新する）
- 互換層（`fcsim_compat.h`）で複数のカーネルを一つのソースから支える

### F. 配布・カーネル互換（追加候補）

今のままでは「開発用カーネルの virtme-ng ゲストでしか動かない」。targetcli のように実際に使うには、これが最も効く。

- **WSL2 のカーネル**（6.18.58.1-microsoft）は `TARGET_CORE=m`、`SCSI_FC_ATTRS=y` だった。
  ヘッダ（WSL2-Linux-Kernel のソース）を用意すれば、その場でロードできる可能性が高い。
  ただしカーネルの不具合は全 distro を巻き込むので、実験用途と割り切る
- **RHEL / AlmaLinux 9**（5.14 系）: dnf で kernel / kernel-devel が取れる。
  使っている API のうち、`timer_container_of`（6.16〜）、`struct_group`、`scsi_done()`、
  `scsi_host_busy_iter` 等は、バックポート状況を確かめて互換ヘッダで吸収する。
  virtme-ng はディストリのカーネルも起動できるので、テストを同じ仕組みで回せる見込み
- **RHEL 10 / Fedora / Ubuntu**: 6.12 以降なら差分は小さいはず
- 配布形態: DKMS 対応の RPM（モジュールのソース、`tools/`、systemd unit）
- 進め方の案: まず AlmaLinux 9 の kernel-devel でビルドを試し（短い spike）、差分の量を見てから範囲を決める

**決定（§5 の 1）: 対象は WSL2 のカーネルと AlmaLinux 9。AlmaLinux 10 は今は対象外だが、妨げになる選択はしない。**

これを受けた具体的な範囲:

| 対象 | カーネル | ビルド | テスト |
|---|---|---|---|
| 開発用（従来） | 6.18 + KASAN/lockdep | 現行どおり | virtme-ng（現行の `make test`） |
| WSL2 | 6.18.58.1-microsoft | microsoft/WSL2-Linux-Kernel の同じタグのソース + `/proc/config.gz` の設定でヘッダを用意し、out-of-tree ビルド | 同じソース・設定で組んだカーネルを virtme-ng で起動して `make test`。実際の WSL2 へのロードは最後に手動で確認（不具合が全 distro に波及するため） |
| AlmaLinux 9 | 5.14.0-xxx.el9 | kernel-devel を入れてビルド（WSL の distro に入れるだけで、起動はしない） | 同じ RPM のカーネルを virtme-ng で起動して `make test` |
| AlmaLinux 10（将来） | 6.12 系 | — | — |

- 互換は `src/fcsim_compat.h` に集め、カーネルのバージョンではなく「その API があるか」で切り替える
  （RHEL はバックポートが多く、バージョン番号では判断できないため。必要なら Kbuild で機能の有無を検出する）。
  6.12 系の AlmaLinux 10 も、後から同じ仕組みで足せる
**spike の結果（3a と並行で実施）**

- AlmaLinux 9（kernel-devel 5.14.0-741.24.1.el9_9、`dnf download` + `rpm2cpio` で root 不要）:
  互換コード無しでビルド・リンクが通った（未解決シンボル無し）。警告は `scsi_host_alloc()` の const 1 件だけで、
  `fcsim_sht` の const を外して解消済み。RHEL 9.9 は使っている API をほぼバックポート済み。
  実行テストには、そのカーネルを virtme-ng で起動する必要がある。virtme-ng はモジュールを
  ルートファイルシステムの `/lib/modules/<version>` から読むので、WSL の distro に
  kernel-core / kernel-modules-core / kernel-modules のインストール（root 権限）が要る
- WSL2（6.18.58.1-microsoft）: ソースはタグ `linux-msft-wsl-6.18.58.1` で公開されている。
  `target_core_mod`、`target_core_iblock`、`dm-multipath` は `/lib/modules` に入っている。
  `MODVERSIONS=y` のため、`Module.symvers` を得るのに WSL2 カーネルのフルビルドが一度必要（モジュール署名は強制されない）。
  `SCSI_DH_ALUA` は無効なので、ALUA を使う multipathd 設定はそのままでは使えない。
  WSL2 のカーネルは頻繁に更新される（`/lib/modules` に 6.18.40 / 54 / 58 があった）ため、
  「実行中のカーネルのタグを取ってきてビルドする」スクリプトにする
- 結論: 互換層は当面ほぼ不要。F の主な作業は、ビルド・テスト環境（両カーネルを virtme-ng で回す仕組み）と配布物の作成

**F の実施内容**

- ビルド: `make KVER=<release> kver` で `build/<release>/` に別ツリーとしてビルド（`make el9`、`make wsl` はその短縮）。
  `scsi_host_template` の const を外した以外、ソースの互換対応は不要だった
- テスト: `make test-el9` / `make test-wsl` が同じテスト一式を各カーネルの virtme-ng ゲストで流す。
  AlmaLinux 9 はインストール済みのカーネル（`KIMG=/lib/modules/<rel>/vmlinuz`、initramfs 用に busybox）、
  WSL2 は `scripts/build-wsl-kernel.sh` で実行中のカーネルと同じソース・設定から組んだツリーを起動する
- WSL2 のツリーでビルドしたモジュールは、vermagic と、実際の WSL2 の tcm_loop が要求する 43 シンボルの CRC が一致した
  （= 実機の WSL2 にそのまま読み込める見込み）。setlocalversion が付ける `+` は `LOCALVERSION=` で抑止
- カーネルごとの違いでテスト側を直した点: `scsi_transport_fc` / `loop` がモジュール（AlmaLinux 9）、
  `null_blk` と `SCSI_DH_ALUA` が無い（WSL2。hang は loop デバイスに、multipathd は ALUA 無しの設定に切り替え）、
  センスの文字列化（`SCSI_CONSTANTS`）が無い（WSL2）、ディスクが sysfs に出てから開けるまでの時間差
- 配布: AlmaLinux 9 向け DKMS RPM（`packaging/`、`make rpm`）。`make test-rpm` で AlmaLinux 9 のゲストに
  インストールし（ゲストの /usr・/var は overlay なのでホストは汚れない）、dkms によるビルド、modprobe、
  インストールされたツールでの I/O、アンインストールを確認する
- 残り: 実機の WSL2 へのロード確認（手動。不具合は全 distro に波及するので、virtme-ng のテストが通ってから）

- KASAN / lockdep での検証は開発用カーネルで続ける。他の 2 つは「ビルドが通り、テストが通ること」を確認する
- 配布物はまず AlmaLinux 9 向けの DKMS RPM。WSL2 向けは手順書とスクリプトにする（WSL2 のカーネルには
  パッケージ管理されたヘッダが無いため）

### G. FPIN / marginal パス（追加候補）

段階 2 の障害注入の延長。障害ルールに「FPIN を送る」を加え、`fc_host_fpin_rcv()` に Link Integrity / Congestion の
通知を渡す。対象の rport は Marginal 状態になり、FPIN の統計も増える。
multipathd 側に `marginal_pathgroups`（RHEL 9 の 0.8.7 にもある）があるので、「壊れてはいないが品質の悪いパス」を
避ける挙動を試せる。実機では再現しにくい状況なので、エミュレータならではの価値がある。

### H. FC BSG（追加候補）

ELS / CT パススルー（`bsg_request`）を実装すると、ファブリックのネームサーバへの問い合わせ等ができるようになる。
これを使うのは HBAAPI 系の一部の管理ツールに限られるので、優先度は低い。

## 4. 推奨する進め方

| 段 | 内容 | 理由 |
|---|---|---|
| 3a | A（CLI）＋ B（統計） | どちらも小さくリスクが低く、すぐ使い勝手が上がる。CLI は以降の土台 |
| （並行）| F の spike: AlmaLinux 9 の kernel-devel と WSL2 カーネルのヘッダでビルドしてみる | 対象環境は決まった（§5 の 1）。3b 以降で使うカーネル API を選ぶ前に、互換の手間を知っておきたい |
| 3a' | F（互換層、両カーネルでのテスト環境、DKMS RPM） | spike の結果を見て、3a の直後か 3b と並行で進める |
| 3b | C（ゾーニング）。CLI 対応と、ゾーン変更時の RSCN を含む | reconcile の条件追加が中心で、既存設計の延長で済む。NPIV より先にあると、NPIV を試す意味が増す |
| 3c | D（NPIV） | 最も大きい。A と C の上に載せる |
| 任意 | G（FPIN） | 3b の後、障害注入を増やしたくなった時点で。小さく独立している |
| 見送り | E（rtslib upstream） | カーネル upstream を目指さないため（§5 の 2）。ラッパーを配布物に同梱する |
| 保留 | H（BSG） | 需要が出たら |

各段とも、これまでどおり「設計を `docs/design.md` に追記 → 実装 → virtme-ng のテスト追加 → `make test` 全 PASS → コミット」で進める。

## 5. 決めてほしいこと

1. ~~**主な利用環境**~~ → **決定: WSL2 のカーネルと AlmaLinux 9。AlmaLinux 10 は将来の候補**（§3 F に範囲を記載）
2. ~~**カーネル upstream を目指すか**~~ → **決定: 目指さない**。out-of-tree で配布し、E（rtslib upstream）は見送る（§3 E）
3. ~~**ゾーン変更の適用方式**~~ → **決定: ステージングして commit で一括反映**（§3 C に configfs 案）
4. ~~**NPIV の管理面**~~ → **決定: まず sysfs の `vport_create` だけ**。必要になったら configfs に広げる
5. ~~**CLI の形態**~~ → **決定: Python 単一スクリプト**（targetcli と同系統、追加依存なし）
