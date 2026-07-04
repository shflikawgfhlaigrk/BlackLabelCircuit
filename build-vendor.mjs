// One-time vendor bundle: everything the UI needs, single three instance.
import { build } from 'esbuild';
await build({
  stdin: {
    contents: `
      export { default as ForceGraph3D } from '3d-force-graph';
      export { default as SpriteText } from 'three-spritetext';
      export * as THREE from 'three';
      export { UnrealBloomPass } from 'three/examples/jsm/postprocessing/UnrealBloomPass.js';
    `,
    resolveDir: process.cwd(),
  },
  bundle: true,
  format: 'esm',
  minify: true,
  outfile: 'public/vendor/circuit-3d.bundle.mjs',
  logLevel: 'info',
});
