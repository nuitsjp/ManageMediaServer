# Nano C6 / Home Assistant MQTT連携

最低10台の温湿度計を、近くに置いた常時給電のNano C6で受信し、Wi-FiでUbuntuへ送る。
`温湿度計 → Zigbee → Nano C6 → Wi-Fi / MQTT TLS → Mosquitto → Home Assistant`。
USBは書込み・設定・復旧時に使う。現時点で実機は1台のみ。10台以上の実機試験は後日行う。

## 状態

2026年11月7日 JST：本番配備と実機1台のWi-Fi／MQTT TLS送信、HAへの登録を確認済み。
10:43 JSTに使い捨て導入スクリプトが `stage=complete / exit_status=0` で終了した。
HA上で温湿度を表示できることは利用者が確認し、設定・エンティティ登録も読取りで照合した。
USB実機で識別済みの販売名Tuya TH03は `Zbeacon / TH01`。
Wi-Fi／Zigbeeの共存は単一RFを共有するため、容量設定や疑似10台の試験だけでは受信安定性を実証できない。
常用の判断は実配置で10台以上の試験後とし、要件を満たせなければ無線部を分ける。

### 初回の実機結果

| 確認項目 | 結果 |
| --- | --- |
| 診断中の温度・湿度 | 26.81℃・44.16%（2026年11月7日09:50:15 JST受信） |
| MCUの接続状態 | Wi-Fi・MQTT・時刻同期がすべて正常 |
| 完了機器数 | 1台 |
| 保存された診断情報 | event/job/gateway drop、device overflowは0 |
| HA登録 | 温度・湿度とも登録済み、利用者が画面で値を確認 |
| サーバー起動設定 | MQTT／MQTT FWはactive・enabled、既存HAもactive |
| 待受け | 平文は127.0.0.1:1883のみ、TLSは8883＋専用FW |

この値は診断中に保存した実測値であり、現在値を示すものではない。
telemetryはMCU起動60秒時点、温湿度は約72秒時点の受信。記録されたキュー欠落ゼロは、
無線での欠測ゼロや長時間安定性を証明するものではない。
初回の11月7日時点では電池・電圧のMQTT実データは未確認だった（11月14日に下記のとおり取得を確認）。
USBをサーバーから外して別電源で設置した状態、Wi-Fi／MQTT切断・サーバー再起動後の復帰、
10台以上・24時間観測は未確認。

実機結果は `/mnt/data/smarthome/nanoc6/diagnostics/mqtt-bringup-iE4uIcLZ/mqtt-report.json`。
全体作業のバックアップは `/mnt/backup/smarthome/mqtt-bringup-EGB9NQ1R/`、
MQTT導入は `/mnt/backup/smarthome/mqtt-install-g9dmxuiR/`、
更新前のMCU全量バックアップと読戻し結果は `/mnt/backup/smarthome/nanoc6/gateway-update-DnDMhrHV/`。
更新時にbootloader・NVS・Zigbee保存領域の一致を確認し、再ペアリングなしで受信できた。
完了時に使い捨て導入スクリプトを削除した。秘密情報を含む元データ・バックアップはroot専用で保持する。

### 電池情報の更新（2026年11月14日）

利用者から、温湿度は表示されるがbattery・voltageが「切断」になるとの報告。
USB診断で両属性を読めていたため、機種の非対応ではない。
v0.1では起動・MQTT/HA再接続時の再読出しが温湿度だけで、電源クラスターの報告設定もなかった。
電池の自発報告が途絶えたりHAが再接続した場合に、48時間の期限切れから回復できない可能性がある。

v0.2で次を実装。全体86件のテストとビルドを通過し、既存のNVS・Zigbee参加情報を保持して更新した。
**11月14日10:12 JST、電池残量・電圧の新規受信とHA画面表示を確認し、修復スクリプトが正常終了。**

- 起動・MQTT/HA再接続・機器の再参加時に、電源クラスター `0x0001` の電圧 `0x0020` と残量 `0x0021` を取得。
  復帰した機器の短縮アドレスはSDKのIEEE対応表から解決し、保存済みの短縮アドレスを使い回さない。
- Read・Bind・Configure Reportingを、全体で2秒ごとに最大1台のまとまりとして投入する。
  キューが足りない場合はまとまりごと延期し、10台以上での集中や途中欠落を防ぐ。
- 定期報告は最短3600秒・最長21600秒。電圧は0.1V、残量は1ポイントの変化を指定。
  設定要求の送信だけで成功とせず、機器の応答を記録する。
- 欠測・期限接近時は同一機器に最低5分の間隔を置き、直近に通信した機器を優先して再試行。
  通信がない機器への自発的な読出しは6時間に1回まで。初回と明示的な再取得要求は1回読出しを試みる。
- 報告設定の再試行は起動／再参加ごとに最大3回。非対応応答の場合は設定の再送を止め、読出しで補う。
- 電池値を保持値から再発行せず、新規に読めた値だけを送信する。48時間の期限切れ表示は維持する。
- telemetryにファームウェア版、電池の読出し・設定要求数、機器ごとの設定成功・非対応状態を追加。
  USBの `refresh-battery` は同じ頻度制限を使って再取得を要求する。

実機確認には `scripts/ops/verify-nanoc6-battery.py` を更新前から起動する。
新しいファームウェアのtelemetryと、同じ起動後に受信した温度・湿度・残量・電圧、Discoveryを照合する。
以前の起動から残った値や古いファームウェアだけでは成功にしない。
更新・確認の利用者作業は、その時点のGitリビジョンを固定した使い捨てスクリプト1本にまとめる。
報告設定の実応答、MQTT経由の値、HAの4項目の登録と画面表示を確認する。

#### 修正版の実機結果

| 項目 | 確認結果 |
| --- | --- |
| 電池残量・電圧 | 機器報告値100%・2.9V（11月14日10:11:44 JST、新規受信） |
| 温度・湿度 | 26.95℃・40.10%（同10:12:19 JST、新規受信） |
| ファームウェア | `nanoc6-wifi-gateway-0.2`、Wi-Fi／MQTT／時刻同期が正常 |
| 電池の取得・報告設定 | 読出し1回、設定要求1回、成功応答1回、status=0、非対応=false |
| 保存された診断情報 | event/job/gateway/stale drop、未確認再試行、機器上限超過は0 |
| HA | 同じ機器の温度・湿度・電池残量・電圧の4項目を照合、利用者が画面で値を確認 |

新しい起動から約20秒で電池情報、約56秒で温湿度を受信し、起動60秒時点のtelemetryでも設定成功を確認した。
更新時にbootloader・NVS・Zigbee保存領域のバイト一致を確認。既存の機器ID・設定で復帰した。
定期報告の設定受理までの確認であり、6時間間隔での継続受信・10台以上の実機安定性は今後の観測対象。
実機結果は `/mnt/data/smarthome/nanoc6/diagnostics/battery-repair-6uQNN3nR/power-report.json`。
作業バックアップは `/mnt/backup/smarthome/nanoc6/battery-repair-rplV9YRO/`、
更新前の全量フラッシュと読戻し結果は `/mnt/backup/smarthome/nanoc6/gateway-update-YPTbcb6H/`。
使い捨て修復スクリプトと診断用の一時エクスポートは削除。元の結果・バックアップはroot専用で保持する。

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

- v0.3は機器ごとの `最終受信` と `受信状況` をMQTT Discoveryで追加する。最終受信には実際のZigbee受信時刻だけを使う。
  受信状況は「3時間以内に受信」「3時間以上受信なし」「未確認」。電池を抜いた瞬間の切断検出ではない。
  ゲートウェイ再起動後は新たな受信まで状態を未確認とする。時刻のretainは最後に実際に受信した時刻を保持する。
- IEEEと「温湿度計01」〜「温湿度計10」の対応を別のNVS名前空間 `gwnumbers` に保存し、既存の `gwfleet` 形式を維持する。
  別機器への番号の重複や、既存番号の暗黙の付け替えは拒否する。USBで保存結果を読み戻して確認できる。
  MQTT Discoveryのデバイス名にも同じ番号を通知する。HAで使用者が設定した手動名はHA側で優先されることがある。
- v0.3は2026-11-15 JSTに実機へ書込み、bootloader・既存NVS・Zigbee領域が書込み直後に一致することを確認した。
  10台の番号は別途USBを電源再投入して読み戻し、全台一致した。MQTTの番号付きDiscoveryと各台6エンティティのHA登録を確認。
  電源を入れた温湿度計10の新しい温湿度を、v0.3起動後のUSBイベントで確認した。
  画面上の最終受信・受信状況、10台同時通電での安定性、長時間の定期報告は別途確認する。
  フラッシュのバックアップは `/mnt/backup/smarthome/nanoc6/gateway-update-6DmNAN0n`、
  番号設定・検査結果は `/mnt/backup/smarthome/nanoc6/number-install-TQhWw39n` に保存した。
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
   追加には管理者権限を持つアカウントを使う。ボタンが見つからない場合は同じブラウザーで
   [MQTT追加画面](http://192.168.0.23:8123/config/integrations/dashboard/add?domain=mqtt)を開く。
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

### 追加9台の対話登録

既存1台＋追加9台のTuya TH03を想定した `scripts/ops/enroll-nanoc6-sensors.py` を用意している。
利用者は、その時点のコミットを固定した使い捨て `tmp-enroll-nanoc6-th03.sh` 1本をsudoで実行する。
Nano C6はボタンを押さずにUSB接続し、登録完了まで接続を保つ。測定データは既存のWi-Fi/MQTT/TLS経由で確認する。
ファームウェアv0.2のUSB制御を利用し、再書込み・Wi-Fi設定入力・MQTTパスワード入力は行わない。

1. 現在のHA/MQTT機器一覧を既存機器として保存し、追加枠への割当から除外する。進捗・HA登録一覧・配備ファイルをバックアップする。
2. 設置場所を入力し、Enterで参加受付を180秒開く。表示された `READY` の後で、今の1台だけを説明書に従ってペアリングモードにする。
3. 新しいIEEEを検出したら受付を閉じ、機器IDを直ちに保存する。機種情報、新しい温度・湿度・電池残量・電圧、4つのDiscoveryとHA登録を最大10分確認する。
4. 表示した実機IDと設置場所の対応を確認してEnterを押す。次の1台へ進む。
5. 全9台が揃ったら、一覧のリンクからHA画面の値を確認してEnterを押す。設置場所名は対応表に保存し、HAの名前・エリアは各デバイス画面で設定する。

受信が揃わない場合は `r` で同じ機器を再確認、`s` で保留して次へ、`q` またはCtrl+Cで保存して中断する。
再実行すると確認済みの枠をスキップし、途中の枠は保存したIEEEのまま再確認する。
同じ実行中に、設置場所・IEEEの入力待ちの間に受信した非retainの測定値も確認に使う。
入力が終わるたびに電池報告の再受信を要求しない。前回実行の値やHA画面の保存値だけで受信確認を通さない。
待機中は10秒ごとに受信済み項目・未確認項目・残り時間を表示し、進捗ファイルにも保存する。
この実行中にUSBで確認した直近5分以内の通信先があれば、機種情報と測定値の再読出しを要求する。
通信先は前回実行の保存データから流用しない。電池読出しの間隔・再試行はファームウェアの制限を維持する。
スリープ中の機器は説明書で確認した短押しによる起床を利用できる。登録済みの機器をリセットしない。
複数の新規IEEEを検出した場合は自動で設置場所を割り当てず、未割当一覧を保存する。
この場合は実機とIEEEを確実に識別できたときだけ、表示されたIEEEを指定して再開する。
中断・異常時にも受付を閉じてUSB応答を確認する。USB断などで確認できなければ失敗として記録し、受付は最長180秒で自動終了する。
実行中にHAの参加受付ボタンや別のUSB操作を併用しない。

進捗は `/mnt/data/smarthome/nanoc6/enrollment/session.json`、対応表は同じ場所の `session.csv` にroot専用で保存する。
CSVにはIEEE、設置場所、機種、各項目の値と受信時刻（JST）、HAリンクを記録する。
毎回の結果は `/mnt/data/smarthome/nanoc6/diagnostics/enrollment-*`、バックアップは `/mnt/backup/smarthome/nanoc6/enrollment-*`。
実行者が読める診断用コピーを `/tmp/manage-media-nanoc6-enrollment.*` に出力する（認証情報は含まない）。
全9台の受信・利用者確認・受付終了が揃った場合だけ使い捨てスクリプトを削除する。保留時は再開用に保持する。

疑似9台で順次登録・既存機器の保護・中断再開・複数台の誤割当防止を自動検証している。
追加9台の実機登録および10台での継続運用試験は、利用者による登録後に確認する。

### 受信と安定性の確認

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
