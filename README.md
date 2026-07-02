# Zorg

3D space shooter, example application for [zengine](https://github.com/xgallom/zengine). Zig 0.15.2, single executable, `src/main.zig`.

## Build

```sh
git clone https://github.com/xgallom/zengine.git
git clone https://github.com/xgallom/zorg.git
cd zengine && zig build ext -Doptimize=ReleaseFast && cd ..
cd zorg && zig build run
```

`zorg` depends on `../zengine` by relative path (`build.zig.zon`), so the two repos must sit next to each other. See zengine's README for the `ext` step (SDL3, shadercross, cimgui, ...).

## Scene

Set up once in `load`, referenced afterward through `scene_map` (name -> `Scene.Node.Id`):

| node | content |
|---|---|
| `Environment` | background quad, `Planet` (gas giant + ring, rotated per-frame in `updateScene`) |
| `Enemy Ship` | static, wireframe + hull mesh |
| `Ship` | player ship, wireframe + hull mesh, tracked as `ship` |
| `Bullets` | empty parent, `Bullet` children appended on fire, tracked as `bullets` |
| `UI` | dialogue frame |
| lights | 1 ambient, 3 directional (fixed rotations) |

Meshes/materials load from `assets/*.obj` + `*.mtl`. Lighting from `assets/scene.lgh`. Color grading LUT from `assets/lut/basic.cube`. Bloom pass (`gfx.pass.Bloom`) enabled with `intensity = 0.25`.

## Per-frame update (`updateScene`)

- planet: `rotation.y = time_since_start`
- ship: translated directly from `controls` state, on world axes scaled by `config.speed_scale`
- ship: rotated to face mouse position, projected through the active camera's view-projection matrix
- firing (`controls.custom(Controls.firing)`, rate-limited by `firing_timer`, 200ms): appends a `Bullet` child under `Bullets` at the ship's current transform
- each existing bullet: stepped forward along its own `-forward` axis, `200` units/s
- `cleanupBullets`: removes bullets once `|x| >= 380` or `|z| >= 222`

## Controls

Movement/roll always active. Yaw/pitch bound to Q/E/F/R only when mouse is not captured (`F2` toggles capture; captured mode drives ship X/Y directly from those same keys instead).

| key | action |
|---|---|
| W / S | forward / back (z axis) |
| A / D | left / right (x axis) |
| Q / E | yaw (mouse released) / x-axis move (mouse captured) |
| F / R | pitch (mouse released) / y-axis move (mouse captured) |
| C / V | roll |
| Space, X | fire |
| K / L | camera scale (fov / ortho scale) -/+ |
| `[` / `]` | `config.speed_scale` -/+ |
| `=` | toggle camera projection (perspective / orthographic) |
| mouse move | aim (captured mode); also drives camera position when UI hidden |
| mouse click | raycast pick against scene geometry (logs hit triangle + intersection point) |
| F1 | toggle debug UI (property editor, perf, allocs, log windows) |
| F2 | toggle mouse capture |
| Esc | toggle UI (in UI) / quit (out of UI) |

`Config` (mouse speed/inversion, camera-controls mode, speed scale) and `RenderPasses` (bloom) are both exposed through zengine's `ui.PropertyEditor` at runtime.

## Layout

```
src/
  main.zig    load/unload/input/update/render, scene setup, controls
  root.zig    unused zig-init template, not wired into the build
assets/       .obj/.mtl meshes, .lgh lights, lut/, music/
shaders/user/ example custom fragment shader (test.frag.hlsl)
```
