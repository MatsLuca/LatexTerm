#!/bin/zsh
# fresh.sh PANE — restart the demo Claude in PANE with an empty screen (between scenes).
R=${0:A:h}
latexterm focus --pane $1; sleep 0.3
$R/input key ctrl+c; sleep 0.3; $R/input type "/exit" 40; sleep 0.6; $R/input key return; sleep 2.5
latexterm send --pane $1 "clear; ~/Projects/.demo-bin/demo-claude"; sleep 6
