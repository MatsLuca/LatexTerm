import React from "react";
import {
  AbsoluteFill,
  Series,
  interpolate,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { theme } from "./theme";
import { Window } from "./components/Window";
import { Pane } from "./components/Pane";
import {
  ClaudeInputBox,
  ClaudeSpinner,
  Prompt,
  Typed,
} from "./components/TerminalText";
import { Formula } from "./components/Formula";
import {
  NotificationBanner,
  ShortcutBadge,
  TitleCard,
} from "./components/Overlays";

// ————— Chapter 1: the Claude Code cockpit —————

const SceneSingleSession: React.FC = () => {
  const frame = useCurrentFrame();
  const pulse = (Math.sin(frame / 8) + 1) / 2;
  return (
    <AbsoluteFill>
      <Window title="claude — LatexTerm" dotPulse={frame > 55 ? pulse : undefined}>
        <Pane focused>
          <div>
            <Prompt cwd="~/dev/api" />
            <Typed text="claude" startFrame={5} caret={false} />
          </div>
          {frame > 18 && (
            <div style={{ color: theme.accentClaude, marginTop: 6 }}>
              ✻ Welcome to Claude Code
            </div>
          )}
          {frame > 30 && (
            <div style={{ marginTop: 6 }}>
              <span style={{ color: theme.textDim }}>{">"} </span>
              <Typed
                text="refactor the auth middleware and fix the tests"
                startFrame={32}
                cps={2}
              />
            </div>
          )}
          {frame > 62 && (
            <div style={{ marginTop: 10 }}>
              <ClaudeSpinner verb="Refactoring" seconds={3} tokens="4.2k" />
            </div>
          )}
        </Pane>
      </Window>
      <ShortcutBadge
        keys="●"
        label="Live session status — right in the titlebar"
        appearFrame={72}
      />
    </AbsoluteFill>
  );
};

const SceneSplit: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const splitAt = 30;
  const grow = spring({
    frame: frame - splitAt,
    fps,
    config: { damping: 16 },
    durationInFrames: 24,
  });
  const pulse = (Math.sin(frame / 8) + 1) / 2;
  return (
    <AbsoluteFill>
      <Window title="claude — LatexTerm" dotPulse={pulse}>
        <Pane focused={frame < splitAt}>
          <div style={{ color: theme.accentClaude }}>
            ✻ Welcome to Claude Code
          </div>
          <div style={{ marginTop: 6 }}>
            <span style={{ color: theme.textDim }}>{">"} </span>
            refactor the auth middleware and fix the tests
          </div>
          <div style={{ marginTop: 10 }}>
            <ClaudeSpinner verb="Refactoring" seconds={8} tokens="12.6k" />
          </div>
        </Pane>
        {frame >= splitAt && (
          <div
            style={{
              flex: grow,
              display: "flex",
              minWidth: 0,
              opacity: grow,
            }}
          >
            <Pane focused>
              <div>
                <Prompt cwd="~/dev/web" />
                <Typed text="claude" startFrame={splitAt + 20} />
              </div>
              {frame > splitAt + 40 && (
                <div style={{ color: theme.accentClaude, marginTop: 6 }}>
                  ✻ Welcome to Claude Code
                </div>
              )}
              {frame > splitAt + 52 && (
                <div style={{ marginTop: 10 }}>
                  <ClaudeInputBox />
                </div>
              )}
            </Pane>
          </div>
        )}
      </Window>
      <ShortcutBadge
        keys="⌘T"
        label="New pane — auto-tiled, own shell, own session"
        appearFrame={8}
        hideFrame={95}
      />
    </AbsoluteFill>
  );
};

const SceneCli: React.FC = () => {
  const frame = useCurrentFrame();
  const cmd = 'latexterm send --pane 2 "run the e2e suite"';
  const typedDone = 12 + Math.ceil(cmd.length / 1.8);
  const pulse = (Math.sin(frame / 8) + 1) / 2;
  return (
    <AbsoluteFill>
      <Window title="zsh — LatexTerm" dotPulse={pulse}>
        <Pane focused={frame <= typedDone + 10}>
          <div>
            <Prompt cwd="~/dev/api" />
            <Typed text={cmd} startFrame={12} cps={1.8} />
          </div>
          {frame > typedDone + 14 && (
            <div style={{ color: theme.green }}>ok · pane 2</div>
          )}
        </Pane>
        <Pane accent={theme.accentClaude} focused={frame > typedDone + 10}>
          <div style={{ color: theme.accentClaude }}>
            ✻ Welcome to Claude Code
          </div>
          <div style={{ marginTop: 10 }}>
            <ClaudeInputBox
              text={
                frame > typedDone + 10
                  ? cmd.split('"')[1].slice(
                      0,
                      Math.max(0, Math.floor((frame - typedDone - 10) * 2))
                    )
                  : ""
              }
            />
          </div>
          {frame > typedDone + 34 && (
            <div style={{ marginTop: 10 }}>
              <ClaudeSpinner verb="Running e2e" seconds={1} tokens="0.8k" />
            </div>
          )}
        </Pane>
      </Window>
      <ShortcutBadge
        keys="$"
        label="Drive any pane from scripts & agents — the latexterm CLI"
        appearFrame={16}
      />
    </AbsoluteFill>
  );
};

const SceneNotify: React.FC = () => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill>
      <Window title="zsh — LatexTerm">
        <Pane>
          <div>
            <Prompt cwd="~/dev/api" />
            latexterm send --pane 2 "run the e2e suite"
          </div>
          <div style={{ color: theme.green }}>ok · pane 2</div>
        </Pane>
        <Pane accent={theme.accentClaude} focused>
          <div style={{ color: theme.accentClaude }}>
            ✻ Welcome to Claude Code
          </div>
          {frame < 25 ? (
            <div style={{ marginTop: 10 }}>
              <ClaudeSpinner verb="Running e2e" seconds={38} tokens="21k" />
            </div>
          ) : (
            <>
              <div style={{ color: theme.green, marginTop: 10 }}>
                ✔ 42 tests passed · 3 files changed
              </div>
              <div style={{ marginTop: 10 }}>
                <ClaudeInputBox />
              </div>
            </>
          )}
        </Pane>
      </Window>
      <NotificationBanner
        title="Claude ist fertig"
        body="Pane 2 · run the e2e suite"
        appearFrame={32}
      />
      <ShortcutBadge
        keys="⚡"
        label="Hooks → OSC 5522: get notified the moment a session needs you"
        appearFrame={45}
      />
    </AbsoluteFill>
  );
};

// ————— Chapter 2: live LaTeX —————

const SceneLatex: React.FC = () => {
  const frame = useCurrentFrame();
  const cmd = `printf '%s\\n' '$E=mc^2$ and $\\frac{n(n+1)}{2}$'`;
  const typedDone = 10 + Math.ceil(cmd.length / 1.8);
  const blockAt = typedDone + 55;
  return (
    <AbsoluteFill>
      <Window title="zsh — LatexTerm">
        <Pane focused>
          <div>
            <Prompt />
            <Typed text={cmd} startFrame={10} cps={1.8} caret={false} />
          </div>
          {frame > typedDone + 8 && (
            <div style={{ marginTop: 8, display: "flex", alignItems: "center", gap: 10 }}>
              <Formula latex="E=mc^2" appearFrame={typedDone + 12} />
              <span>and</span>
              <Formula
                latex="\frac{n(n+1)}{2}"
                appearFrame={typedDone + 20}
              />
            </div>
          )}
          {frame > blockAt && (
            <>
              <div style={{ marginTop: 14 }}>
                <Prompt />
                <Typed
                  text="cat gauss.tex"
                  startFrame={blockAt + 2}
                  caret={false}
                />
              </div>
              <div
                style={{
                  marginTop: 12,
                  display: "flex",
                  justifyContent: "center",
                }}
              >
                <Formula
                  latex="\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}"
                  display
                  appearFrame={blockAt + 16}
                  fontSize={30}
                />
              </div>
            </>
          )}
        </Pane>
      </Window>
      <ShortcutBadge
        keys="$…$"
        label="Formulas render live over their source — real grid, real KaTeX, no OCR"
        appearFrame={typedDone + 26}
      />
    </AbsoluteFill>
  );
};

// ————— Assembly —————

export const DemoVideo: React.FC = () => {
  return (
    <AbsoluteFill style={{ background: theme.desktop }}>
      <Series>
        <Series.Sequence durationInFrames={75}>
          <TitleCard
            title="LatexTerm"
            subtitle="A native macOS terminal, built as a cockpit for Claude Code — with live LaTeX rendering."
          />
        </Series.Sequence>
        <Series.Sequence durationInFrames={130}>
          <SceneSingleSession />
        </Series.Sequence>
        <Series.Sequence durationInFrames={140}>
          <SceneSplit />
        </Series.Sequence>
        <Series.Sequence durationInFrames={150}>
          <SceneCli />
        </Series.Sequence>
        <Series.Sequence durationInFrames={110}>
          <SceneNotify />
        </Series.Sequence>
        <Series.Sequence durationInFrames={55}>
          <TitleCard small title="And it renders LaTeX. Live." />
        </Series.Sequence>
        <Series.Sequence durationInFrames={185}>
          <SceneLatex />
        </Series.Sequence>
        <Series.Sequence durationInFrames={80}>
          <TitleCard
            small
            title="LatexTerm"
            subtitle="github.com/MatsLuca/LatexTerm — ⌘T panes · live session status · latexterm CLI · KaTeX overlays"
          />
        </Series.Sequence>
      </Series>
    </AbsoluteFill>
  );
};
