# tcm_fcsim

FC HBA なしで「FC ストレージ」をエミュレーションする Linux カーネルモジュール。

- initiator 側には本物の FC HBA と同じく `/sys/class/fc_host`・`fc_remote_ports`・`fc_transport` が現れ、
  LUN は普通の SCSI ディスク（`/dev/sdX`）として見える
- target 側は LIO の fabric module（`fcsim`）なので、LUN・ACL は targetcli で管理できる
- 両者を同じモジュール内の仮想ファブリックでつなぐ。リンクの上げ下げ、ゾーニング、障害注入（遅延・無応答・エラー）、
  FPIN、RSCN、fc_host 統計があり、dm-multipath / multipathd と組み合わせて試せる

設計は `docs/design.md`、今後の計画は `docs/stage3-plan.md`。

## 対応カーネル

| カーネル | ビルド | テスト |
|---|---|---|
| 開発用 6.18（KASAN / lockdep 有効、`scripts/build-kernel.sh`） | `make` | `make test` |
| AlmaLinux 9（5.14.0-*.el9） | `make el9` | `make test-el9` |
| WSL2（`uname -r` の 6.18.x-microsoft-standard-WSL2） | `make wsl` | `make test-wsl` |

AlmaLinux 9 向けには DKMS RPM も作れる（`make rpm` → `rpmbuild/RPMS/noarch/`。要 rpm-build）。
インストールすると dkms が各カーネル向けにモジュールを組み、`modprobe tcm_fcsim` で依存モジュールごと読み込める。
ツールは `/usr/bin/fcsimctl`、`fcsim-targetcli`、`fcsim-targetctl`。`make test-rpm` はこの RPM を
AlmaLinux 9 のゲストに入れて確認する（ホストには入れない）。

テストはいずれも virtme-ng のゲスト内で動く（`scripts/vng-run.sh`）。結果とゲストの dmesg は `.test-out/` に残る。

### 必要なもの

共通: gcc、make、virtme-ng、qemu-kvm、targetcli（python3-rtslib）、sg3_utils、device-mapper-multipath、
（RPM を作る場合）rpm-build、dkms

- AlmaLinux 9 のカーネル: そのリリースの `kernel-core`、`kernel-modules-core`、`kernel-modules`、`kernel-devel`、
  および virtme-ng が initramfs を作るための `busybox`（EPEL）。WSL の distro に入れるだけで、起動には影響しない
  ```
  sudo dnf install kernel-core-<rel> kernel-modules-core-<rel> kernel-modules-<rel> kernel-devel-<rel> busybox
  ```
- WSL2 のカーネル: パッケージのヘッダが無いので、同じリリースのソースから組む（数十分かかる。一度だけ）
  ```
  scripts/build-wsl-kernel.sh            # ~/build/wsl2-<version> に取得・設定・ビルド
  make wsl                               # build/<release>/tcm_fcsim.ko
  ```
  WSL2 のカーネルが更新されたら（`uname -r` が変わったら）、もう一度組み直す。
  WSL2 のカーネルには `SCSI_DH_ALUA` が無いので、multipathd は ALUA なし（`hardware_handler "0"`）で使う

## 使い方の例

```
# モジュール（依存モジュールを先に）
sudo modprobe target_core_mod
sudo modprobe scsi_transport_fc
sudo insmod build/$(uname -r)/tcm_fcsim.ko      # 開発用カーネルでは src/tcm_fcsim.ko

# target 側: ramdisk を LUN 0 として出し、initiator に ACL を与える
sudo tools/fcsim-targetcli /backstores/ramdisk create rd0 1G
sudo tools/fcsim-targetcli /fcsim create naa.2100000000000001
sudo tools/fcsim-targetcli /fcsim/naa.2100000000000001/luns create /backstores/ramdisk/rd0
sudo tools/fcsim-targetcli /fcsim/naa.2100000000000001/acls create naa.10000000c9000001

# initiator 側: 仮想 HBA ポートを作ると、ログインして LUN が /dev/sdX として現れる
sudo tools/fcsimctl host create 10:00:00:00:c9:00:00:01
sudo tools/fcsimctl status

# 障害注入とリンク操作
sudo tools/fcsimctl fault set 10:00:00:00:c9:00:00:01 21:00:00:00:00:00:00:01 delay_ms=100
sudo tools/fcsimctl link 10:00:00:00:c9:00:00:01 down

# ゾーニング（編集してから commit で一括反映）
sudo tools/fcsimctl zone create z1 10:00:00:00:c9:00:00:01 21:00:00:00:00:00:00:01
sudo tools/fcsimctl zone mode on
sudo tools/fcsimctl zone commit

# FPIN: T1 のリンク品質が悪い、とファブリックが通知する（multipathd の marginal_pathgroups fpin が反応する）
sudo tools/fcsimctl fpin li 21:00:00:00:00:00:00:01 link_failure

# 保存・復元（target 側は fcsim-targetctl、initiator 側とゾーニングは fcsimctl）
# 注意: fcsim-targetctl は LIO 全体が対象（下記）
sudo tools/fcsim-targetctl save /etc/target/fcsim-target.json
sudo tools/fcsimctl save /etc/target/fcsim-initiator.json

# 片付け（作ったものだけを消す）
sudo tools/fcsimctl clear
sudo tools/fcsim-targetcli /fcsim delete naa.2100000000000001
sudo tools/fcsim-targetcli /backstores/ramdisk delete rd0
sudo rmdir /sys/kernel/config/target/fcsim
sudo rmmod tcm_fcsim
```

**注意**: `fcsim-targetctl` は fcsim fabric を登録してから `targetctl` を実行するだけで、fabric を区別しない。
`save` は iSCSI など他の fabric も含めた LIO 全体を書き出し、`restore` と `clear` は LIO 全体を消してから
（`restore` は復元を）行う。他の LIO の設定があるホストでは、`restore`・`clear` を使わず、
上の片付けの例のように `fcsim-targetcli` で fcsim の target と backstore を個別に消すこと。
`fcsimctl` は fcsim の範囲（initiator ポートとゾーニング）しか触らない。

**注意**: カーネルモジュールなので、不具合はホストのカーネルごと巻き込む。WSL2 では全 distro が同じカーネルを
共有しているため、他の distro も止まる。まず virtme-ng のテスト（`make test-wsl` 等）で確認してから使うこと。

WSL2 の実機で初めて試すときは `sudo scripts/wsl-try.sh` を使うとよい。事前チェック（カーネルとモジュールの一致など）の後、
段階ごとに確認を取りながら「読み込みと取り外しだけ」→「ramdisk の LUN への I/O、link down / up」と進み、
作ったものだけを片付けてモジュールを外す（他の LIO の設定には触れない）。I/O に使うディスクは fcsim の HBA の
sysfs から辿って自前の ramdisk であることを確かめてから使う。

## ディレクトリ

```
src/        カーネルモジュール
tools/      fcsimctl（initiator 側・ファブリックの CLI）、fcsim-targetcli / fcsim-targetctl（targetcli ラッパー）
scripts/    カーネルのビルド、virtme-ng の起動、テストの実行
tests/      virtme-ng ゲスト内で動くテスト
docs/       設計・計画
```
