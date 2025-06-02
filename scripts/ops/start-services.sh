#!/bin/bash

set -e

sudo systemctl restart immich
sudo systemctl restart jellyfin

echo "ImmichとJellyfinのサービスを開始（再起動）しました。"