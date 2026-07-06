import React, { useMemo } from "react";
import { interpolate, spring, useCurrentFrame, useVideoConfig } from "remotion";
import katex from "katex";
import "katex/dist/katex.min.css";
import { theme } from "../theme";

// Real KaTeX — same renderer the app bundles. Appears with a soft scale-in,
// mirroring how overlays pop over their source text.
export const Formula: React.FC<{
  latex: string;
  appearFrame?: number;
  display?: boolean;
  fontSize?: number;
}> = ({ latex, appearFrame = 0, display = false, fontSize = 24 }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const html = useMemo(
    () =>
      katex.renderToString(latex, {
        throwOnError: false,
        displayMode: display,
      }),
    [latex, display]
  );
  if (frame < appearFrame) return null;
  const s = spring({
    frame: frame - appearFrame,
    fps,
    config: { damping: 14, mass: 0.6 },
  });
  const opacity = interpolate(frame - appearFrame, [0, 6], [0, 1], {
    extrapolateRight: "clamp",
  });
  return (
    <span
      style={{
        display: "inline-block",
        transform: `scale(${0.6 + 0.4 * s})`,
        opacity,
        color: theme.formula,
        fontSize,
        background: display ? "transparent" : "rgba(142,199,255,0.07)",
        borderRadius: 6,
        padding: display ? 0 : "0 6px",
      }}
      dangerouslySetInnerHTML={{ __html: html }}
    />
  );
};
