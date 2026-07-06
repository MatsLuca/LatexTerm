import React from "react";
import { Composition } from "remotion";
import { DemoVideo } from "./DemoVideo";
import { COMP_H, COMP_W, LiveDemo } from "./LiveDemo";
import { PolishedDemo } from "./PolishedDemo";
import { FPS } from "./theme";

export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Composition
        id="Polished"
        component={PolishedDemo}
        durationInFrames={1355}
        fps={FPS}
        width={1280}
        height={800}
      />
      <Composition
        id="Live"
        component={LiveDemo}
        durationInFrames={1355}
        fps={FPS}
        width={COMP_W}
        height={COMP_H}
      />
      <Composition
        id="Demo"
        component={DemoVideo}
        durationInFrames={925}
        fps={FPS}
        width={1280}
        height={800}
      />
    </>
  );
};
