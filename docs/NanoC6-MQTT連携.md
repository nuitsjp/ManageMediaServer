# Nano C6 / Home Assistant MQTT連携

最低10台の温湿度計を、近くに置いた常時給電のNano C6で受信し、Wi-FiでUbuntuへ送る。
`温湿度計 → Zigbee → Nano C6 → Wi-Fi / MQTT TLS → Mosquitto → Home Assistant`。
USBは書込み・設定・復旧時に使う。現時点で実機は1台のみ。10台以上の実機試験は後日行う。

## 状態

2026年11月7日 JST：実装とビルド・自動テストを準備。本番配備とWi-Fi実機疎通は実施前。
USB実機で識別済みの販売名Tuya TH03は `Zbeacon / TH01`。
Wi-Fi／Zigbeeの共存は単一RFを共有するため、容量設定や疑似10台の試験だけでは受信安定性を実証できない。
常用の判断は実配置で10台以上の試験後とし、要件を満たせなければ無線部を分ける。

## 配置

| 用途 | 場所 |
| --- | --- |
| コード・運用ファイル | `/home/ubuntu/repos/ManageMediaServer` |
| 本番Compose | `/home/mediaserver/ManageMediaServer/docker/mosquitto/docker-compose.yml` |
| ブローカー設定・データ | `/mnt/data/smarthome/mosquitto/config`、`data` |
| CA秘密鍵 | `/etc/manage-smarthome/mqtt-private/`（root専用） |
| クライアントの認証情報 | `/etc/manage-smarthome/mqtt-clients.json`（root専用） |
| Nano C6のWi-Fi設定等 | `/etc/manage-smarthome/nanoc6-provision.json`（root専用、USBで設定） |
| MCU内の設定・識別情報 | NVSの `gwconfig` / `gwfleet`。認証情報を含むため本体も適切に管理する |
| 実機結果 | `/mnt/data/smarthome/nanoc6/diagnostics/mqtt-bringup-*/` |
| 配置前・フラッシュ全量バックアップ | `/mnt/backup/smarthome/mqtt-*`、`nanoc6/gateway-update-*` |

サービスは `smarthome-mqtt.service` と `smarthome-mqtt-firewall.service`。
既存と同じmediaserverのCompose＋systemdで起動し、FW適用を前提にする。
`deploy-managed-files.sh --mqtt-only` はMQTT関連のGit管理ファイルだけを配置する。

## 通信と登録

- 外部からは宅内LANのTCP 8883だけを許可し、CA・サーバー名・有効期間を検証するTLSを使用。
  TCP 1883は `127.0.0.1` のみで待受け、LANからはFWでも拒否する。HAは同じサーバー上から1883へ認証付きで接続。
- Mosquitto 2.1.2-alpineのlinux/amd64イメージをdigest固定。
  gateway・HA・診断用でアカウントを分け、ACLでトピックを限定。匿名接続は拒否。
- 機器はIEEEアドレスで識別。直下20台、アプリ管理32台、SDKネットワークサイズ64。
  Endpoint 1の既知のmanufacturer/modelの組合せだけを変換する。未知機種の生データはUSB側に残す。
- 機器ごとに温度・湿度・電池報告値・電圧を登録する。Discoveryはretain、測定値は**非retain**。
  `smarthome/nanoc6/<IEEE>/<temperature|humidity|battery|voltage>/state` に値と実際の受信時刻を送る。
  ACKを受けるまで最新値を保持し、切断後は未確認メッセージの古い送信キューを破棄して最新値から再試行。
  受信から120秒を超えた値は再送せず、破棄件数を診断情報に記録。
- 温湿度は3時間、電池は48時間更新がなければHAで期限切れ。最後の受信はJSON属性 `received_at`（UTC Unix秒）。
  個々の値の時刻を別々に扱い、欠測や不正値を0で埋めない。ゲートウェイの切断はLWTでofflineにする。
- HAのMQTT起動通知でもDiscoveryを再送する。再起動後は過去の測定値を新規受信として再発行しない。
- Nano C6ゲートウェイのHAボタンから参加受付を180秒だけ開く。起動時は閉じる。
  参加の指示はretainされたものを無視する。最初の1台は既存のZigbee保存領域を保持して更新する。
- NTPで時刻が整うまでTLS接続を開始しない。2.4 GHz Wi-Fiと外向きのNTP通信が必要。
- Zigbee受信コールバックは固定長キューへコピーし、Wi-Fi/TLS/NVS処理は別タスク。
  キュー欠落・機器上限超過・古い値の破棄・未確認メッセージ再試行・空きヒープをtelemetryで通知する。

## 配備と利用者操作

利用者へは、その時点のGitリビジョンを固定した使い捨てスクリプト1本を渡す。
入力するWi-FiパスワードやMQTTパスワードをログ・Git・チャットに出さない。

1. 現状確認・バックアップ後、ブローカー・証明書・ACL・FW・systemdを配置する。
2. 新しいHA接続用MQTTパスワードを端末上で設定する。HAログイン用と分ける。
3. Nano C6の現在の4MBフラッシュを全量保存してから、アプリとパーティション表・OTA選択領域だけを更新。
   既知のパーティション表だけを許可し、bootloader・NVS・Zigbee保存領域のバイト一致を読み戻して検証する。
4. USBを抜いて5秒待ち、ボタンを押さずにつなぎ直す。端末の案内に従ってEnterを押す。
5. 2.4 GHzのSSIDとWi-Fiパスワードを端末上で入力。USBからNVSへ設定する。
6. MQTT/TLS接続と、今回新たに受信した1台の温湿度・Discovery・欠落ゼロのtelemetryを確認する。
7. HAの「設定 → デバイスとサービス → 統合を追加 → MQTT」で、broker=`127.0.0.1`、port=`1883`、
   username=`homeassistant`、手順2のパスワードを設定。このloopback接続のTLSは無効。
8. 温湿度計の値がHA画面に表示されてからEnter。HA設定とエンティティ登録もファイルの読取りで照合する。
   HAの`.storage`を直接編集しない。実際の画面の値は利用者の確認として記録する。
9. 成功時は使い捨てスクリプトを削除し、Codex用の秘密情報を除いた結果を一時出力する。

サーバー導入に失敗した場合は、ブローカー停止を確認して追加設定を切り戻し、データをバックアップ側へ退避する。
停止を確認できない場合はデータとFWを保持し、復旧失敗を報告する。取得したイメージは残る。
MCU書込み・読み戻しに失敗した場合は全量バックアップから復元を試み、結果を表示する。
Wi-Fi接続や受信試験の失敗で、成功した書込みを自動で繰り返さない。
再実行時は確認済みブローカー・MCUイメージと保存した接続設定を再利用する。
パスワード変換用コンテナも読み取り専用ルートとし、ツールが使う `/tmp` だけにtmpfsを用意する。
Composeのtmpfs指定はカンマを含む文字列を引用し、意図せず複数のマウントに分かれることを防ぐ。
Composeで解釈した設定から、配備前にネットワーク無効・専用ユーザー・読み取り専用ルートの検査用コンテナを起動し、
tmpfsの作成と書込みを確認する。失敗時には新しい認証情報やサービスを配置しない。
導入前に同じコンテナ設定でダミーパスワードの変換を検査する。
導入失敗後、選択済みパスワードは `install-smarthome-mqtt.sh --reuse-credentials <root専用バックアップ>` で再利用できる。
単体の配備完了・HA登録確認は10台試験や24時間観測の代わりにはならない。

## 後日の10台試験

HAのゲートウェイの参加受付ボタンを押して、温湿度計を順にペアリングする。必要に応じて受付を開き直す。
各台のIEEEと設置場所を記録し、HAで名称・エリアを設定する。
診断用 `smarthome_mqtt.py observe --expected-devices 10 --duration 86400 --output <root専用結果ファイル>` は
各台の新しい温度・湿度、Discovery、ゲートウェイ状態、キュー欠落を確認するための道具。
全台の新しい温湿度を得たら終了するため、**このコマンド単体は24時間安定性試験ではない**。
root操作が必要な際は、その時点の状態に合わせて使い捨てスクリプトにまとめる。
24時間試験では各台・各測定項目の受信間隔と欠測、再参加、Wi-Fi/AP・MQTTの切断復帰、
Nano C6・サーバー再起動後の復帰と機器ID維持を記録する。
同じ値が続く場合も、実際の新規受信があることを記録で判定する。

## 開発・検証

`scripts/ops/build-nanoc6-gateway.sh` がArduino-ESP32 3.3.6でビルドし、全ソースと成果物のSHA-256を記録。
アプリ領域は2.5MiBへ拡張するが、NVS `0x9000`、Zigbee領域 `0x3EA000` などはUSB診断版と同じ。
OTA無線更新は今回実装していない。生成物・ツールチェーンは従来どおりホーム配下のキャッシュに置く。
`build-reference.json` と一致する成果物だけを書き込む。MCUの全量バックアップは秘密情報を含むのでroot専用で保持。

自動テストはMCUと同じC++変換コードで10台分の識別・値・期限切れ・容量超過を確認し、
配備と同一イメージのMosquittoを隔離したloopback上で動かしてTLS・認証・ACL・Discovery retain・
測定値非retain・疑似10台の配送を検証する。本番へ疑似センサーを送らない。

## 開発元資料

- [ESP32-C6のRF共存](https://docs.espressif.com/projects/esp-idf/en/v5.5/esp32c6/api-guides/coexist.html)
- [Arduino-ESP32 3.3.6](https://github.com/espressif/arduino-esp32/tree/3.3.6)
- [Home Assistant MQTT](https://www.home-assistant.io/integrations/mqtt/)
- [MQTT Sensor](https://www.home-assistant.io/integrations/sensor.mqtt/)
- [Mosquitto設定](https://mosquitto.org/man/mosquitto-conf-5.html)
