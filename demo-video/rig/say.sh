#!/bin/zsh
# say.sh PANE TEXT [CPS] — types TEXT into pane PANE like a person (typewriter via latexterm send),
# then presses Return as a real key (a sent "\r" becomes a newline inside Claude's input box).
pane=$1; text=$2; cps=${3:-32}
latexterm focus --pane $pane; sleep 0.25
for (( i=1; i<=${#text}; i++ )); do
  latexterm send --pane $pane --no-enter -- "${text[i]}"
  sleep $(( (0.6 + RANDOM % 90 / 100.0) / cps ))
done
sleep 0.35
${0:A:h}/input key return
