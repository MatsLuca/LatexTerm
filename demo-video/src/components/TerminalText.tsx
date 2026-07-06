import React from "react";
import { useCurrentFrame } from "remotion";
import { theme } from "../theme";

export const Prompt: React.FC<{ cwd?: string }> = ({ cwd = "~" }) => (
  <span>
    <span style={{ color: theme.textDim }}>{cwd} </span>
    <span style={{ color: theme.green }}>❯ </span>
  </span>
);

// Types `text` starting at `startFrame`, `cps` chars per frame
export const Typed: React.FC<{
  text: string;
  startFrame: number;
  cps?: number;
  color?: string;
  caret?: boolean;
}> = ({ text, startFrame, cps = 1.6, color, caret = true }) => {
  const frame = useCurrentFrame();
  const chars = Math.max(0, Math.floor((frame - startFrame) * cps));
  const shown = text.slice(0, chars);
  const done = chars >= text.length;
  const caretVisible =
    caret && frame >= startFrame && (!done || Math.floor(frame / 16) % 2 === 0);
  return (
    <span style={{ color }}>
      {shown}
      {caretVisible && (
        <span
          style={{
            display: "inline-block",
            width: 11,
            height: 24,
            background: theme.accent,
            verticalAlign: "text-bottom",
            marginLeft: 1,
          }}
        />
      )}
    </span>
  );
};

// Claude Code spinner line, glyph rotates like the real TUI
export const ClaudeSpinner: React.FC<{
  verb?: string;
  seconds?: number;
  tokens?: string;
}> = ({ verb = "Pondering", seconds, tokens }) => {
  const frame = useCurrentFrame();
  const glyphs = ["✻", "✶", "✳", "✽", "∗"];
  const g = glyphs[Math.floor(frame / 6) % glyphs.length];
  const dots = ".".repeat((Math.floor(frame / 12) % 3) + 1);
  return (
    <div style={{ color: theme.accentClaude }}>
      {g} {verb}
      {dots}{" "}
      <span style={{ color: theme.textDim }}>
        {seconds !== undefined && `(${seconds + Math.floor(frame / 30)}s`}
        {tokens && ` · ${tokens} tokens`}
        {seconds !== undefined && " · esc to interrupt)"}
      </span>
    </div>
  );
};

// Claude Code style input box
export const ClaudeInputBox: React.FC<{ text?: string; width?: string }> = ({
  text = "",
  width = "100%",
}) => (
  <div
    style={{
      border: `1px solid ${theme.textDim}`,
      borderRadius: 6,
      padding: "4px 10px",
      color: text ? theme.text : theme.textDim,
      width,
      whiteSpace: "nowrap",
      overflow: "hidden",
    }}
  >
    <span style={{ color: theme.textDim }}>{">"} </span>
    {text || "Try “fix the build”"}
  </div>
);
