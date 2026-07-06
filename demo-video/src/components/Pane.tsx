import React from "react";
import { theme } from "../theme";

// One terminal tile: focus ring + 4px content inset, like PaneContainerView
export const Pane: React.FC<{
  children: React.ReactNode;
  focused?: boolean;
  accent?: string;
  flex?: number;
}> = ({ children, focused = false, accent = theme.accent, flex = 1 }) => {
  return (
    <div
      style={{
        flex,
        borderRadius: 10,
        background: theme.paneBg,
        border: focused
          ? `2px solid ${accent}`
          : `1px solid ${theme.paneBorder}`,
        opacity: focused ? 1 : 0.82,
        overflow: "hidden",
        padding: 14,
        display: "flex",
        flexDirection: "column",
        fontFamily: theme.font,
        fontSize: 20,
        lineHeight: "34px",
        color: theme.text,
        minWidth: 0,
      }}
    >
      {children}
    </div>
  );
};
