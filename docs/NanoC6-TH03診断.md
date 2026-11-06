# Nano C6 / Tuya TH03 USB 診断

運用時は Nano C6 を温湿度計の近くに常時給電で設置し、Zigbee 受信値を Wi-Fi/MQTT over TLS で
Ubuntu の Mosquitto、Home Assistant へ送る。USB は開発時のみ。温湿度計は**最低10台**。
今回は USB 接続下で1台の TH03 の機種情報と温湿度データを取得する。Wi-Fi・MQTT は未実装。
既存 HA やメディアサービスへの配備・再起動は行わない。

## 配置

| 用途 | パス |
| --- | --- |
| 診断用ファームウェア | `firmware/nanoc6/usb_probe/usb_probe.ino` |
| ビルド | `scripts/ops/build-nanoc6-probe.sh` |
| USB受信・解析 | `scripts/ops/capture-nanoc6-usb.py` |
| 機器・測定値の証跡 | `/mnt/data/smarthome/nanoc6/diagnostics/usb-probe-*/` |
| 書き換え前のフラッシュ全体 | `/mnt/backup/smarthome/nanoc6/usb-probe-*/original-flash.bin` |
| ビルド環境・生成物 | `/home/ubuntu/.cache/manage-media-smarthome/`（Git 管理外） |

## 現在の確認結果

2026年11月7日 JST、接続し直した機器を `303a:1001 Espressif USB JTAG/serial debug unit` として確認。
対象は `/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_9C:CC:01:33:A1:50-if00`、
実体は確認時 `/dev/ttyACM0`。シリアル番号を固定し別の機器への誤書き込みを防ぐ。
ユーザーにはポート操作権限がないため、sudo を使う使い捨てスクリプト1本で実行する。
**診断用ファームウェアの書き込み、1台の参加・機種情報・温湿度の読出しと自動レポート受信を確認済み。**

販売名 Tuya TH03 の実機が返した識別情報は manufacturerName=`Zbeacon`、modelID=`TH01`、
appVersion=147、swBuildID=`0122052017`。Endpoint 1、profile `0x0104`、device `0x0302`、
入力クラスターは `0x0000/0x0003/0x0001/0x0020/0x0402/0x0405`、出力は `0x0019`。
温度・湿度・電池クラスターの bind 応答は成功。今回の個体は標準属性から値を取得でき、独自DP解読は不要だった。

| 取得方法 | 温度 | 相対湿度 | 電池報告値 |
| --- | --- | --- | --- |
| 初回読出し | 27.08℃ (`940a`) | 42.99% (`cb10`) | 3.0V / 100% |
| 続く自動レポート | 27.20℃ (`a00a`) | 43.67% (`0f11`) | 3.0V / 100% |
| 保存ログ内の最終レポート | 26.99℃ (`8b0a`) | 43.00% (`cc10`) | 3.0V / 100% |

自動レポートの温度受信は `2026-11-06T23:04:22.681678+00:00`、
湿度は `2026-11-06T23:04:22.751141+00:00`。同時測定とは扱わない。
最終レポートは温度 `2026-11-06T23:06:04.981839+00:00`、湿度 `2026-11-06T23:06:05.156745+00:00`。
観測したイベントの event/job drop はともに0。本体表示との照合と10台以上の実機試験は未確認。
元の証跡は `/mnt/data/smarthome/nanoc6/diagnostics/usb-probe-ReBLstxg/`。
旧解析器はこの組み合わせを未対応として `complete=false` にした。
修正後の解析器で元のイベントを再解析し、`complete_devices=1`、`complete=true`、欠落0、終了値0を確認。
再解析結果は `/mnt/data/smarthome/nanoc6/diagnostics/redecoded-MEmLyEbm/report.json`、
再解析前のレポートと使用した解析器・スクリプトは `/mnt/backup/smarthome/nanoc6/redecode-jUZnoRrg/`。
元のイベントとレポートは変更せず、再解析前後でイベントのSHA-256が一致した。

Arduino CLI 1.5.1、Arduino-ESP32 3.3.6（同梱 ESP Zigbee SDK）、ESP32-C6 generic board、
USB CDC、4MB、Zigbee ZCZR partition/mode でビルドした。
Nano C6 の SoC/フラッシュ/USB に合わせた設定であり、1台でのUSB診断を実機確認した。
環境取得はホーム内のキャッシュで行い、OS パッケージ・既存サービスは変更していない。

再ビルドは `scripts/ops/build-nanoc6-probe.sh`。設定済みツールチェーンで並列1を使用する。
新規環境では Arduino CLI 1.5.1 と公式 ESP32 package index を用意し `esp32:esp32@3.3.6` を導入する。
CLI設定はキャッシュの `toolchain/arduino-cli.yaml`、core は `arduino-data/`、
生成物は `build/nanoc6-usb-probe/`。SDK更新時はビルドと実機試験をやり直す。

## 10台以上への備え

- 直下の子機20台、アプリのIEEEアドレス記録32台、SDKネットワークサイズ64を設定。
  **設定値であり実証済み容量ではない**。まず1台、その後10台以上で評価する。
- 短縮アドレスは再参加で変わるため、IEEEアドレスを主キーにする。
- コールバックは固定長キューにコピーし、USB出力・リクエスト送信は別処理。
  キュー溢れは検知し、不完全な記録を成功扱いにしない。
- Wi-Fi追加後は10台以上の同時復帰・欠測・電池への影響を実配置で試験する。
  Nano C6 の単一RFによる Wi-Fi/Zigbee 共存リスクは引き続き評価する。

## 診断用ファームウェア

- coordinator を形成・復元し、起動時の参加受付は閉じる。SDKの不揮発領域は再起動で消さない。
- USBの `join` で180秒だけ参加受付、`close` で閉じる。
- 参加通知から active endpoints、simple descriptor を取得し、profile/device IDとクラスター一覧を記録。
- Basic の manufacturer/model/version 等、温度 `0x0402`、湿度 `0x0405`、電源 `0x0001` の値を読む。
  対象クラスターを bind して通常レポートも受信する。報告間隔はこの段階では書き換えない。
- Tuya初期化で用いる Basic 属性の読出しを含む。独自 `0xEF00` は生データを保存し、DPを推測しない。
- `status` は状態を返すだけ。`interview 1234` は16進NWKアドレスを再調査する。
- 初期チャンネル20。10台を参加させる前に Wi-Fi共存試験で採用チャンネルを確定する。

## 解釈と証跡

TH03 は販売名。個体ごとに modelID/manufacturerName を実機から取得して形式を確定する。
今回の `TH01` / `Zbeacon` は開発元の SONOFF コンバーター内の該当 fingerprint と照合し、
温度・湿度をいずれも raw/100 と解釈する。販売名だけで TS0201 や Tuya独自DP機として扱わない。
開発元コンバーターでは TS0201 の `_TZ3000_itnrsufe` が湿度 raw/10、
`_TZ3000_bguser20` と `_TZ3000_xr3htd96` が raw/100。
既知の組み合わせだけで倍率を選び、未知の組み合わせはrawを保存して完了判定を保留する。
電池残量は報告値として扱い、電圧も保存する。

イベントは `events.jsonl`、SDK起動出力を含む原文は `serial.log`、
機器別の機種情報・記述子・値・生データ・受信時刻は `report.json`。
温度と湿度は受信時刻を別々に保持。同じ値の新規受信も記録し、欠測を0で埋めない。
`capture-nanoc6-usb.py --events <保存済みevents.jsonl> --output <新しい出力ディレクトリ>` は
USBを開かずに再解析する。元の受信時刻を必須とし、再解析時刻は別の `replayed_at` に保存する。
終了値は0=既知の温湿度取得、2=情報不足、3=キュー欠落。再解析によって新規受信を証明するものではない。

## 利用者による実機作業

使い捨て `.sh` 1本が次を行う。書き換え中は USB 接続を維持する。

1. シリアル番号、ソース・生成物の整合性、ESP32-C6/4MB を確認する。
2. `/mnt/backup` のマウントを確認し、現状の4MBフラッシュを全量バックアップ・SHA-256記録。
3. 診断用4MBイメージを書き込む。既存のNano C6ファームウェアと保存情報は置き換わる。
4. USBを一度抜き、5秒待って**ボタンを押さず**に接続し直して Enter を押す。
   USBから通常起動状態を確認し、参加受付を開く。
5. **READYの表示後、TH03 1台だけを説明書どおりペアリングモードへ入れる。**
   未接続で電源が入っている状態とペアリングモードは同じとは限らない。
6. 最大5分記録する。機種情報と既知の温湿度が取得できたら受付を閉じ、追加30秒記録して終了。
7. 結果を表示・保存し journal に終了状態と取得結果を記録。成功時は使い捨てスクリプトを削除。

想定と異なる場合は生データを残して中止し、Wi-Fi/MQTTへは進まない。本体表示と値を照合して確定する。
復元が必要な場合はUSB識別情報・バックアップのハッシュを確認した別の使い捨てスクリプトで全量イメージを戻す。
フラッシュバックアップは資格情報・ネットワーク鍵を含む可能性があるためroot専用で保管しGitへ入れない。

ボタンを押しながら接続して入った書込みモードは、ESP32-C6の内蔵USB経由のリセットだけでは
解除されない場合がある。今回の `CoordinatorNotReady` は通常のUSB抜き差しで解消し、その後参加・受信できた。
同症状では電源を入れ直して `--capture` だけを再実行する。再書き込みやZigbeeネットワークの消去は不要。

## 開発元資料

- [Nano C6](https://docs.m5stack.com/en/core/NanoC6)
- [M5Stack Zigbee例](https://docs.m5stack.com/en/arduino/m5nanoc6/zigbee)
- [Arduino-ESP32 3.3.6](https://github.com/espressif/arduino-esp32/tree/3.3.6/libraries/Zigbee)
- [Tuya機種コンバーター](https://github.com/Koenkk/zigbee-herdsman-converters/blob/master/src/devices/tuya.ts)
- [Zbeacon TH01の識別・処理](https://github.com/Koenkk/zigbee-herdsman-converters/blob/master/src/devices/sonoff.ts)
- [標準湿度の変換](https://github.com/Koenkk/zigbee-herdsman-converters/blob/master/src/converters/fromZigbee.ts)
- [内蔵USBによるリセットの制限](https://docs.espressif.com/projects/esptool/en/latest/esp32c6/esptool/advanced-options.html)
- [Tuya初期化](https://github.com/Koenkk/zigbee-herdsman-converters/blob/master/src/lib/tuya.ts)
- [TH03実機資料](https://pvvx.github.io/TS0201_TZ3000_TH03/)
