#!/bin/bash
# Optik-Probe: identische Ausgabe in zwei Terminals für den Side-by-side-Vergleich
# (Terminal-Optik R30). Nutzung: bash docs/optik-probe.sh
E=$'\e'
printf '%s\n' "${E}[1m▐▛███▜▌${E}[0m   ${E}[1mClaude Code${E}[0m v2.x                                    ${E}[2m~/Documents/…/claude-werkstatt${E}[0m"
printf '%s\n' "${E}[1m▝▜█████▛▘${E}[0m  Dark+ · JetBrains Mono 20 · Padding · Cursor █"
echo
printf '%s\n' "${E}[1mBold${E}[0m  ${E}[3mItalic${E}[0m  ${E}[1;3mBold-Italic${E}[0m  ${E}[4mUnderline${E}[0m  ${E}[2mDim${E}[0m  ${E}[7m Invers ${E}[0m  ${E}[9mStrike${E}[0m"
printf '%s\n' "0O 1lI| {}[]() <=> != -> => ::  äöü ß € ∑ ∫ ∂ √ ≠ ≈ ∞  ─│┌┐└┘├┤┬┴┼ ░▒▓█"
echo
printf '%s' "ANSI  "; for i in 0 1 2 3 4 5 6 7; do printf "${E}[3${i}m■${E}[0m ${E}[9${i}m■${E}[0m "; done; echo
printf '%s' "bg    "; for i in 0 1 2 3 4 5 6 7; do printf "${E}[4${i}m  ${E}[0m${E}[10${i}m  ${E}[0m"; done; echo
printf '%s' "bold  "; for i in 1 2 3 4 5 6; do printf "${E}[1;3${i}mtext${E}[0m "; done; echo
echo
for r in 16 52 88 124 160 196; do printf '%s' "      "; for i in $(seq $r $((r+35))); do printf "${E}[48;5;${i}m ${E}[0m"; done; echo; done
printf '%s' "      "; for i in $(seq 232 255); do printf "${E}[48;5;${i}m ${E}[0m"; done; echo
echo
printf '%s\n' "${E}[38;5;77m●${E}[0m ${E}[1mGelesen${E}[0m  ${E}[38;5;214m●${E}[0m ${E}[1mBearbeitet${E}[0m  ${E}[38;5;171m●${E}[0m ${E}[1mGeplant${E}[0m  ${E}[38;5;203m●${E}[0m ${E}[1mFehler${E}[0m  ${E}[38;5;111m●${E}[0m ${E}[1mHinweis${E}[0m"
echo
printf '%s\n' "${E}[38;5;245mclaude-werkstatt  ·  ${E}[38;5;77m master${E}[38;5;245m ✓ synced  ·  ${E}[38;5;111mFable 5 medium${E}[38;5;245m  ·  ${E}[38;5;111m4s${E}[0m"
printf '%s\n' "${E}[38;5;245mctx ${E}[48;5;236m          ${E}[0m${E}[38;5;245m --  ·  5h ${E}[38;5;214m82%${E}[38;5;245m ◔47m  7d ${E}[38;5;171m20%${E}[38;5;245m ◔5d2h  F5 ${E}[38;5;203m40%${E}[38;5;245m  ·  ${E}[38;5;77m0.00€${E}[38;5;245m Σ1787.55€${E}[0m"
printf '%s\n' "${E}[38;5;203m▶▶ bypass permissions on${E}[0m ${E}[38;5;245m(shift+tab to cycle) · ← 1 agent${E}[0m"
echo
printf '%s' "${E}[2m>${E}[0m "
