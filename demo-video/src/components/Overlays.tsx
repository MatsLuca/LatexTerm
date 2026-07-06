import React from "react";
import {
  interpolate,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { theme } from "../theme";

// Bottom-center keyboard shortcut pill, e.g. ⌘T
export const ShortcutBadge: React.FC<{
  keys: string;
  label: string;
  appearFrame: number;
  hideFrame?: number;
}> = ({ keys, label, appearFrame, hideFrame }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  if (frame < appearFrame || (hideFrame !== undefined && frame > hideFrame))
    return null;
  const s = spring({ frame: frame - appearFrame, fps, config: { damping: 13 } });
  return (
    <div
      style={{
        position: "absolute",
        bottom: 34,
        left: 0,
        right: 0,
        display: "flex",
        justifyContent: "center",
        transform: `translateY(${(1 - s) * 30}px)`,
        opacity: s,
      }}
    >
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 12,
          background: "rgba(10,8,8,0.85)",
          border: "1px solid rgba(255,255,255,0.15)",
          borderRadius: 12,
          padding: "10px 18px",
          fontFamily: theme.uiFont,
          fontSize: 20,
          color: theme.text,
          boxShadow: "0 10px 30px rgba(0,0,0,0.5)",
        }}
      >
        <span
          style={{
            fontFamily: theme.font,
            background: "rgba(255,255,255,0.12)",
            borderRadius: 7,
            padding: "3px 12px",
            fontSize: 21,
          }}
        >
          {keys}
        </span>
        <span style={{ color: theme.textDim }}>{label}</span>
      </div>
    </div>
  );
};

// macOS notification banner, top-right
export const NotificationBanner: React.FC<{
  title: string;
  body: string;
  appearFrame: number;
}> = ({ title, body, appearFrame }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  if (frame < appearFrame) return null;
  const s = spring({
    frame: frame - appearFrame,
    fps,
    config: { damping: 15, mass: 0.7 },
  });
  return (
    <div
      style={{
        position: "absolute",
        top: 24,
        right: 24,
        width: 380,
        transform: `translateX(${(1 - s) * 420}px)`,
        background: "rgba(40,36,36,0.92)",
        border: "1px solid rgba(255,255,255,0.14)",
        borderRadius: 16,
        padding: "14px 18px",
        display: "flex",
        gap: 14,
        alignItems: "center",
        fontFamily: theme.uiFont,
        boxShadow: "0 14px 40px rgba(0,0,0,0.5)",
        backdropFilter: "blur(20px)",
      }}
    >
      <div
        style={{
          width: 42,
          height: 42,
          borderRadius: 10,
          background: theme.windowBg,
          border: `1px solid ${theme.paneBorder}`,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          color: theme.accent,
          fontFamily: theme.font,
          fontSize: 24,
          flexShrink: 0,
        }}
      >
        $
      </div>
      <div style={{ minWidth: 0 }}>
        <div style={{ color: "#fff", fontSize: 18, fontWeight: 600 }}>
          {title}
        </div>
        <div style={{ color: theme.textDim, fontSize: 16 }}>{body}</div>
      </div>
    </div>
  );
};

// Chapter / title cards
export const TitleCard: React.FC<{
  title: string;
  subtitle?: string;
  small?: boolean;
}> = ({ title, subtitle, small = false }) => {
  const frame = useCurrentFrame();
  const { fps, durationInFrames } = useVideoConfig();
  const s = spring({ frame, fps, config: { damping: 16 } });
  const out = interpolate(
    frame,
    [durationInFrames - 12, durationInFrames],
    [1, 0],
    { extrapolateLeft: "clamp" }
  );
  return (
    <div
      style={{
        position: "absolute",
        inset: 0,
        background: theme.desktop,
        display: "flex",
        flexDirection: "column",
        justifyContent: "center",
        alignItems: "center",
        gap: 22,
        opacity: out,
        fontFamily: theme.uiFont,
      }}
    >
      <div
        style={{
          fontSize: small ? 44 : 60,
          fontWeight: 600,
          letterSpacing: -0.8,
          color: "rgba(255,255,255,0.96)",
          transform: `translateY(${(1 - s) * 14}px)`,
          opacity: s,
          textAlign: "center",
          padding: "0 60px",
        }}
      >
        {title}
      </div>
      {subtitle && (
        <div
          style={{
            fontSize: small ? 20 : 23,
            fontWeight: 400,
            color: theme.textDim,
            transform: `translateY(${(1 - s) * 22}px)`,
            opacity: s * 0.9,
            textAlign: "center",
            padding: "0 90px",
            lineHeight: 1.5,
          }}
        >
          {subtitle}
        </div>
      )}
    </div>
  );
};
