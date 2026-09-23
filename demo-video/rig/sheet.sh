#!/bin/zsh
# sheet.sh TAKE FROM TO FPS OUT.png — contact sheet (6 columns, left→right, top→bottom);
# cell i shows FROM + i/FPS seconds. For finding exact cut points.
t=$1 a=$2 b=$3 fps=$4 out=$5
ffmpeg -v error -y -ss $a -to $b -i ${0:A:h}/../recordings/takes/$t.mov -vf "fps=$fps,scale=330:-1,pad=iw+6:ih+6:3:3:yellow@0,tile=6x8" -frames:v 1 $out
