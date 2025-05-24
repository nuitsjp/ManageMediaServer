#!/bin/bash
# スクリプト権限設定
# すべてのシェルスクリプトに実行権限を付与

find scripts -name "*.sh" -exec chmod +x {} \;
echo "スクリプトファイルに実行権限を付与しました"
