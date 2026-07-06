import React from "react";
import { AbsoluteFill } from "remotion";
import { theme } from "../theme";

// Frameless LatexTerm window: transparent titlebar, traffic lights, vibrancy-ish bg
export const Window: React.FC<{
  children: React.ReactNode;
  title?: string;
  dotPulse?: number; // 0..1 pulsing session dot opacity, undefined = no dot
  dotColor?: string;
}> = ({ children, title = "LatexTerm", dotPulse, dotColor }) => {
  return (
    <AbsoluteFill
      style={{
        background: theme.desktop,
        justifyContent: "center",
        alignItems: "center",
      }}
    >
      <div
        style={{
          width: "88%",
          height: "84%",
          borderRadius: 14,
          background: theme.windowBgTranslucent,
          border: `1px solid rgba(255,255,255,0.12)`,
          boxShadow: "0 30px 80px rgba(0,0,0,0.55)",
          display: "flex",
          flexDirection: "column",
          overflow: "hidden",
          backdropFilter: "blur(30px)",
        }}
      >
        <div
          style={{
            height: 44,
            display: "flex",
            alignItems: "center",
            padding: "0 18px",
            gap: 8,
            flexShrink: 0,
          }}
        >
          {["#ff5f57", "#febc2e", "#28c840"].map((c) => (
            <div
              key={c}
              style={{
                width: 13,
                height: 13,
                borderRadius: "50%",
                background: c,
              }}
            />
          ))}
          <div
            style={{
              flex: 1,
              textAlign: "center",
              color: theme.textDim,
              fontFamily: theme.uiFont,
              fontSize: 15,
              fontWeight: 500,
              display: "flex",
              justifyContent: "center",
              alignItems: "center",
              gap: 8,
            }}
          >
            {title}
            {dotPulse !== undefined && (
              <span
                style={{
                  width: 9,
                  height: 9,
                  borderRadius: "50%",
                  background: dotColor ?? theme.accentClaude,
                  opacity: 0.35 + 0.65 * dotPulse,
                  boxShadow: `0 0 ${6 + 6 * dotPulse}px ${
                    dotColor ?? theme.accentClaude
                  }`,
                }}
              />
            )}
          </div>
          <div style={{ width: 55 }} />
        </div>
        <div style={{ flex: 1, display: "flex", padding: 8, gap: 8 }}>
          {children}
        </div>
      </div>
    </AbsoluteFill>
  );
};
