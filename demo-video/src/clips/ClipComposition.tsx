import React from "react";
import { CalculateMetadataFunction, Composition, staticFile } from "remotion";
import { Clip, clipFrames, COMP, Edls, takesOf } from "./Clip";
import { SPECS } from "./specs";

type Props = { name: string; edls: Edls | null };

const calc: CalculateMetadataFunction<Props> = async ({ props }) => {
  const spec = SPECS[props.name];
  const edls: Edls = {};
  for (const t of takesOf(spec)) edls[t] = await (await fetch(staticFile(`takes/${t}.cuts.json`))).json();
  return { durationInFrames: clipFrames(edls, spec), fps: 30, props: { ...props, edls } };
};

const Comp: React.FC<Props> = ({ name, edls }) => (edls ? <Clip spec={SPECS[name]} edls={edls} /> : null);

export const ClipCompositions: React.FC = () => (
  <>
    {Object.keys(SPECS).map((name) => (
      <Composition key={name} id={`clip-${name}`} component={Comp} defaultProps={{ name, edls: null }}
        calculateMetadata={calc} durationInFrames={300} fps={30} width={COMP.w} height={COMP.h} />
    ))}
  </>
);
