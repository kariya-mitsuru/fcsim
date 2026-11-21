# tcm_fcsim 設計

FC HBA なしで「FC ストレージ」をエミュレーションする Linux カーネルモジュール。

- initiator 側には本物の FC HBA と同じく `/sys/class/fc_host`・`fc_remote_ports`・`fc_transport` が生える
  （`scsi_transport_fc` を使う SCSI LLD）
- target 側は LIO の fabric module として実装し、LUN・ACL は targetcli でそのまま管理できる
- 両者を同一モジュール内の仮想ファブリックでつなぐ（tcm_loop の FC 版。多対多）

対象カーネル: Linux 6.18 系（開発は v6.18.64 + virtme-ng）。

## 1. 全体像

```
            ┌──────────────────── tcm_fcsim.ko ────────────────────┐
 initiator  │  iport (仮想 HBA)        仮想ファブリック       tport  │  target
 SCSI層 ◀──▶│  Scsi_Host + fc_host ◀──▶ port_id割当   ◀──▶ LIO se_wwn│◀──▶ LIO core
 sd/sg      │  rport (相手 tport)       ログイン管理        tpgt_1   │    backstore
            │                          (reconcile)                  │    ACL / LUN
            └──────────────────────────────────────────────────────┘
 設定:      /sys/kernel/config/fcsim/...            /sys/kernel/config/target/fcsim/...
            (独自 configfs)                          (LIO configfs = targetcli)
```

## 2. 決定事項

| 項目 | 決定 |
|---|---|
| 名前 | モジュール `tcm_fcsim`、LIO fabric 名 `fcsim`（nvme の `/sys/class/fcloop` と衝突させない） |
| ファブリックの置き場所 | カーネル内には「仕組み」（ポート・port_id・ログイン/ログアウト・link 状態・既定の全対全接続）だけを置く。ゾーニング定義や障害シナリオ等の「ポリシー」は将来ユーザ空間ツールが configfs に書く |
| ACL 無し initiator の扱い | tcm_qla2xxx と同じ既定値: `generate_node_acls=1`, `demo_mode_login_only=1`, `demo_mode_write_protect=1`, `cache_dynamic_acls=1`。= ログインは通り rport は見えるが、LUN は明示 ACL を持つ initiator にしか見えない。TPG attrib で変更可能 |
| target 側の fc_host | 出さない（target 側のエミュレーションは目的外） |
| WWN 表記 | configfs 上は小文字コロン区切り `xx:xx:xx:xx:xx:xx:xx:xx`（tcm_qla2xxx と同じ。rtslib の naa 形式と相互変換可能） |

## 3. オブジェクトモデル

| オブジェクト | 実体 | 主な属性 |
|---|---|---|
| ファブリック | モジュール内に 1 つ | switch WWN（`fabric_name`）、Domain ID `0x01`、port_id = `0x01AA00`（AA = 1..254 を IDA で払い出し） |
| iport | `Scsi_Host` + `fc_host` | WWPN（ディレクトリ名）、WWNN（既定は WWPN の先頭バイトを `0x20` にしたもの）、port_id、port_state、speed、link |
| tport | LIO `se_wwn` + `tpgt_1`（1 つのみ） | WWPN（ディレクトリ名）、WWNN、port_id、online = TPG 登録済み かつ `enable=1` |
| nexus | ログイン済み (iport, tport) の組 | initiator 側 `fc_rport`、target 側 `se_session` |

### ログイン / ログアウト（reconcile 方式）

状態変更（host 作成/削除、link up/down、TPG enable/disable/削除、ACL 作成、LIO からの close_session 等）は
`fcsim_mutex` の下で状態フラグを書き換えた後、単一の ordered workqueue 上の **reconcile** を起動する。
reconcile は「あるべき nexus 集合」と現状を突き合わせ、差分をログイン/ログアウトする。

- あるべき nexus: iport が link up かつ削除中でない × tport が online、かつ LIO から close 要求されていない
- configfs の store/mkdir/rmdir や TPG enable/drop からは reconcile 完了まで待つ（同期）。
  ACL 作成・close_session など LIO のロックを持っている可能性がある経路からは起動のみ（非同期）

ログイン:
1. `target_setup_session(tpg, ..., initiator=iport WWPN, private=nexus)`
   — ACL 無しかつ demo mode 無効なら `-EACCES` → ログイン拒否（rport は作らない）
2. nexus を iport の RCU リストに追加（I/O パスから検索可能にする）
3. `fc_remote_port_add(shost, 0, {wwnn, wwpn, port_id, FCP_TARGET})` → transport が自動スキャン（REPORT LUNS は LIO が ACL に従って応答）

ログアウト（逆順）:
1. `fc_remote_port_delete(rport)` → I/O ブロック、dev_loss_tmo 開始
2. nexus を RCU リストから外し `synchronize_rcu()`
3. `target_stop_session` → `target_wait_for_sess_cmds` → `target_remove_session`

LIO の `close_session`（ACL 削除等）との排他: `target_shutdown_sessions` は `nacl_sess_lock` の下で
未停止のセッションを ACL のリストから外し、ロックを外してから `close_session` を呼ぶ。
ログアウト側は同じロックの下で `target_stop_session` し、セッションが既にリストから外れていれば
`close_session` 実行中とみなして、その完了（nexus の `close_done`）を待ってから解放する。

同じ WWPN で dev_loss_tmo 内に再ログインすると transport は同じ rport / SCSI target を再利用する（multipath の path 復旧と同じ挙動）。

nexus の検索は `rport->dd_data` を使わず、iport の nexus リストを相手 WWPN で RCU 検索する
（`fc_remote_port_add` は rport 再利用時に `dd_data` をゼロクリアし、かつ戻る前に ONLINE にするため）。

## 4. I/O パス

```
queuecommand(sc)
  fc_remote_port_chkready(rport)            … blocked なら DID_IMM_RETRY 等
  rcu_read_lock → nexus 検索 → target_init_cmd(se_sess) → rcu_read_unlock
  target_submit_prep(cdb, scsi_sglist(sc)) … initiator の SGL をそのまま渡す（コピー無し）
  target_submit()                           … TARGET_QUEUE_SUBMIT（LIO の workqueue で実行）
LIO 完了
  write_pending  → target_execute_cmd（データは既に SGL にある）
  queue_data_in / queue_status → result・sense・residual を設定
  check_stop_free → transport_generic_free_cmd
  release_cmd    → scsi_done(sc)
```

- `se_cmd` とセンスバッファは `scsi_cmd_priv(sc)`（`cmd_size`）に置き、追加割り当て無し
- エラー処理: `eh_timed_out = fc_eh_timed_out`、`eh_abort_handler` → `TMR_ABORT_TASK`、
  `eh_device_reset_handler` → `TMR_LUN_RESET`（いずれも先に `fc_block_scsi_eh`）
- EH が SUCCESS / FAST_IO_FAIL を返すとミッドレイヤはその sc を即座に再発行しうる（`fcsim_cmd` を再利用）。
  LIO は state list から外した後に `release_cmd` を呼ぶため、TMR の応答（特に `TASK_DOES_NOT_EXIST`）
  だけではコマンドが解放済みとは限らない。そこで:
  - 完了は `fcsim_cmd_done()` に集約し、RCU read 区間内で `released` を立ててから `scsi_done`
  - EH は対象コマンド（LUN RESET なら当該 LUN の全コマンド）の `released` を待ち（上限 30 秒）、
    `synchronize_rcu()` で `scsi_done` の実行中を待ってから SUCCESS を返す。待ち切れなければ FAILED

## 5. 設定インターフェース

### target 側（LIO configfs / targetcli）

```
/sys/kernel/config/target/fcsim/
  version                       (ro; LIO は tfc_wwn_attrs を fabric 直下に置く)
  <target WWPN>/
    tpgt_1/
      enable
      node_name, port_id, sessions   (ro; WWN ディレクトリには属性を置けないので TPG に置く)
      attrib/{generate_node_acls, cache_dynamic_acls, demo_mode_write_protect,
              prod_mode_write_protect, demo_mode_login_only}
      lun/  acls/<initiator WWPN>/
```

targetcli 上では単一 TPG の fabric（qla2xxx と同じ）として `tpg1` を挟まず
`/fcsim/naa.XXXXXXXXXXXXXXXX/{luns,acls}` と見える。

### initiator 側 + ファブリック（独自 configfs）

```
/sys/kernel/config/fcsim/
  fabric_name, version          (ro)
  hosts/
    <initiator WWPN>/           mkdir で仮想 HBA ポート（Scsi_Host）が生える
      port_name, port_id, scsi_host, targets   (ro)
      node_name                 (rw, link down 中のみ変更可)
      link                      (rw: up / down)
```

`/sys/class/fc_host/hostN/issue_lip` に書くと、未ログインの組み合わせを再試行し、既存 rport を再スキャンする。

### targetcli 連携

AlmaLinux 9 の rtslib は fabric 一覧が Python コードに固定（qla2xxx すら無効化されている）。
当面は `fcsim` 用の FabricModule を登録してから targetcli を起動するラッパー（`tools/fcsim-targetcli`、
`tools/fcsim-targetctl` は save/restore/clear 用）を用意し、将来 rtslib-fb upstream にパッチを送る。
`targetctl clear` は fabric ディレクトリ（`/sys/kernel/config/target/fcsim`）を残すため、
rmmod 前に `rmdir` が必要（他の fabric と同じ）。

## 6. ソース構成

```
src/
  fcsim.h         共通定義
  fcsim_main.c    モジュール init/exit、ファブリック（port_id、reconcile、login/logout）、WWN ユーティリティ
  fcsim_ini.c     Scsi_Host / fc_function_template、queuecommand、EH、rport add/delete
  fcsim_tgt.c     target_core_fabric_ops、LIO configfs（wwn/tpg/attrib/acl）
  fcsim_cfs.c     独自 configfs（/sys/kernel/config/fcsim）
tools/fcsim-targetcli
tests/            virtme-ng ゲスト内で実行するテスト（race-fcsim.sh はテスト専用モジュールパラメータ
                  dbg_release_delay_ms / dbg_close_delay_ms で競合の窓を広げる回帰テスト）
```

## 7. 段階

| 段階 | 内容 |
|---|---|
| 1 (MVP) | 単一ファブリック・全対全、iport/tport、ログイン、rport・スキャン、READ/WRITE、link up/down、ABORT/LUN RESET、KASAN/lockdep 有効で作成〜削除〜rmmod がクリーン |
| 2 | `terminate_rport_io`・dev_loss_tmo の厳密化、障害注入（遅延・無応答・エラー応答）、RSCN、multipath テスト（2 iport × 2 tport） |
| 3 | ゾーニング、NPIV（`vport_create`）、fc_host 統計、rtslib upstream、initiator 側 CLI |

## 8. 既知の制限（段階 1）

- バックエンドが応答しなくなると、`fcsim_mutex` を持ったままのセッション drain と上限の無い TMR 待ちで
  ファブリック操作全体が止まる（段階 2 でタイムアウト化）
- `eh_target_reset_handler` / `eh_host_reset_handler` は未実装（段階 2）
- T10-PI（DIF/DIX）は非対応
- LUN マップ変更時の自動再スキャンはしない（実機同様、LIO が REPORTED LUNS DATA HAS CHANGED の UA を返すのみ）。
  `issue_lip` で再スキャンできる
- 見える LUN が 1 つも無い間は SCSI 層が scsi_target を回収するため `fc_transport/target*` は現れない
  （rport は存在する。実機で LUN マスキングされていないアレイと同じ挙動）
