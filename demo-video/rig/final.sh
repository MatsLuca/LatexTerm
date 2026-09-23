#!/bin/zsh
# final.sh CLIP — the release path: Remotion PNG sequence (no JPEG, no intermediate video) → every 2nd
# frame (15 fps) → one animated WebP in mixed mode (lossless where that is smaller, else lossy q90) →
# docs/media/CLIP.webp, plus out/sheet-CLIP.png (one frame per second) to check the camera.
# final.sh CLIP --render-only / --encode-only split the two stages (encode is single-threaded: run it
# in the background while the next clip renders).
set -e
c=$1; d=${0:A:h}/..; seq=$d/out/seq-$c
if [[ $2 != --encode-only ]]; then
  rm -rf $seq; mkdir -p $seq $d/../docs/media
  (cd $d && npx remotion render clip-$c $seq --sequence --image-format=png --log=error --concurrency=7)
fi
[[ $2 == --render-only ]] && exit 0
files=($(ls $seq/*.png | sort -V | awk 'NR%2==1'))
img2webp -loop 0 -mixed -lossy -q 90 -m 6 -d 67 $files -o $d/../docs/media/$c.webp >/dev/null 2>&1
printf "file '%s'\n" $files > $seq/list.txt
ffmpeg -v error -y -f concat -safe 0 -r 15 -i $seq/list.txt -vf "select=not(mod(n\,15)),scale=533:-1,tile=4x10" -frames:v 1 $d/out/sheet-$c.png
rm -rf $seq
ls -l $d/../docs/media/$c.webp | awk -v c=$c '{printf "%s %.1f MB\n", c, $5/1e6}'
