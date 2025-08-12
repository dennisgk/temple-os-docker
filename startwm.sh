#!/bin/bash
# This script will be run inside the container to launch QEMU instead of XFCE

#exec qemu-system-x86_64 \
#  -hda /workspace/disk.img \
#  -m 1024M \
#  -vga std \
#  -display gtk,zoom-to-fit=on,show-menubar=off

PIPE=/config/pcspk_audio/pcspk_out.raw
if [ ! -p "$PIPE" ]; then
    rm -f "$PIPE"
    mkfifo "$PIPE"
    chmod 777 "$PIPE"
fi

python3 -u /config/pcspk_audio/pcspk_stream_server.py >> /config/pcspk_audio/stream.log 2>&1 &

sleep 5

exec qemu-system-x86_64 \
  -enable-kvm \
  -hda /workspace/disk.img \
  -m 1024M \
  -vga std \
  -display gtk,zoom-to-fit=on \
  -audiodev none,id=audio0 \
  -machine pcspk-audiodev=audio0
