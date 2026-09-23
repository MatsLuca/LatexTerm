#!/bin/zsh
# webp.sh CLIP [WIDTH] [FPS] [Q] — out/clip-CLIP.mp4 → ../docs/media/CLIP.webp (animated, loops).
# Animated WebP keeps 24-bit colour (GIF bands on the dark gradients) and autoplays on GitHub.
c=$1 w=${2:-1100} fps=${3:-15} q=${4:-72}
dir=${0:A:h}/..; tmp=$(mktemp -d); mkdir -p $dir/../docs/media
ffmpeg -v error -i $dir/out/clip-$c.mp4 -vf "fps=$fps,scale=$w:-2:flags=lanczos" $tmp/f_%04d.png
img2webp -loop 0 -lossy -q $q -m 4 -d $((1000 / fps)) $tmp/f_*.png -o $dir/../docs/media/$c.webp >/dev/null 2>&1
rm -rf $tmp; ls -lh $dir/../docs/media/$c.webp | awk '{print $5, $9}'
