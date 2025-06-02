#!/bin/bash

set -e

sudo systemctl stop immich
sudo systemctl stop jellyfin

echo "ImmichとJellyfinのサービスを停止しました。"