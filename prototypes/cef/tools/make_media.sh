#!/usr/bin/env bash
# Generates small silent/test-pattern media fixtures with ffmpeg (CI only;
# binaries are never committed). Usage: make_media.sh <out dir>
set -euo pipefail
out="$1"; mkdir -p "$out"
v="-f lavfi -i testsrc=size=320x240:rate=25:duration=3"
a="-f lavfi -i sine=frequency=440:duration=3"
ffmpeg -hide_banner -loglevel error -y $v -c:v libx264 -pix_fmt yuv420p -profile:v baseline -movflags +faststart -an "$out/h264.mp4"
ffmpeg -hide_banner -loglevel error -y $a -c:a aac -movflags +faststart "$out/aac.m4a"
ffmpeg -hide_banner -loglevel error -y $v -c:v libvpx-vp9 -b:v 200k -an "$out/vp9.webm"
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libsvtav1; then
  ffmpeg -hide_banner -loglevel error -y $v -c:v libsvtav1 -preset 12 -pix_fmt yuv420p -an "$out/av1.webm"
else
  ffmpeg -hide_banner -loglevel error -y $v -c:v libaom-av1 -cpu-used 8 -pix_fmt yuv420p -an "$out/av1.webm"
fi
ffmpeg -hide_banner -loglevel error -y $a -c:a libopus "$out/opus.webm"
for f in "$out"/*; do ffprobe -v error -show_entries stream=codec_name -of csv=p=0 "$f" | tr '\n' ' '; echo " $(basename "$f") $(stat -c %s "$f") bytes"; done
