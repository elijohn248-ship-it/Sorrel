#!/usr/bin/env bash
# Generates the codec fixtures for gate 10 with ffmpeg on the CI runner.
# Synthetic test patterns and tones only; never committed to git.
set -euo pipefail
out="$1"; mkdir -p "$out"
v=(-f lavfi -i "testsrc=size=320x240:rate=25")
a=(-f lavfi -i "sine=frequency=440:sample_rate=48000")
t=(-t 3)
ffmpeg -hide_banner -loglevel error -y "${v[@]}" "${a[@]}" "${t[@]}" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$out/h264_aac.mp4"
ffmpeg -hide_banner -loglevel error -y "${v[@]}" "${t[@]}" -c:v libx265 -tag:v hvc1 -pix_fmt yuv420p "$out/hevc.mp4" || echo "media: hevc encoder unavailable"
ffmpeg -hide_banner -loglevel error -y "${v[@]}" "${a[@]}" "${t[@]}" -c:v libvpx -b:v 300k -c:a libvorbis -shortest "$out/vp8_vorbis.webm"
ffmpeg -hide_banner -loglevel error -y "${v[@]}" "${a[@]}" "${t[@]}" -c:v libvpx-vp9 -b:v 300k -deadline realtime -cpu-used 8 -c:a libopus -shortest "$out/vp9_opus.webm"
ffmpeg -hide_banner -loglevel error -y "${v[@]}" "${a[@]}" "${t[@]}" -c:v libaom-av1 -cpu-used 8 -crf 40 -b:v 0 -c:a libopus -shortest "$out/av1_opus.webm"
ffmpeg -hide_banner -loglevel error -y "${v[@]}" "${t[@]}" -c:v libaom-av1 -cpu-used 8 -crf 40 -b:v 0 "$out/av1.mp4"
ffmpeg -hide_banner -loglevel error -y "${a[@]}" "${t[@]}" -c:a aac "$out/aac.m4a"
ffmpeg -hide_banner -loglevel error -y "${a[@]}" "${t[@]}" -c:a libopus "$out/opus.webm"
ffmpeg -hide_banner -loglevel error -y "${a[@]}" "${t[@]}" -c:a libmp3lame "$out/mp3.mp3"
ffmpeg -hide_banner -loglevel error -y "${a[@]}" "${t[@]}" -c:a flac "$out/flac.flac"
ls -l "$out"
