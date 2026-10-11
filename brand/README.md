# Brand

Source files for the app icon and web icons. Concept, rejected alternatives and test results are in
`DESIGN.md` › Shapes › Brand.

| File | What it is |
|---|---|
| `app-icon.svg` | The app icon: 1024 square, opaque, edge to edge. macOS 26 applies the rounded mask itself. Also the source of `apple-touch-icon.png`. |
| `app-icon-small.svg` | Simplified variant for the 16px and 32px slots: no caret, one body line. Same full-bleed square. |
| `favicon.svg` | The small variant cropped to the plate, for browser tabs. |
| `mark.svg` | The symbol alone (`#`, caret, heading bar) with no plate, for single-colour use. |

## Rebuild

```bash
~/.claude/skills/design-system/scripts/make-icons.sh brand/app-icon.svg build/brand \
  --small brand/app-icon-small.svg --fullbleed brand/app-icon.svg
cp build/brand/AppIcon.icns Resources/AppIcon.icns
cp brand/favicon.svg build/brand/favicon-32.png build/brand/apple-touch-icon.png site/
```

`scripts/make-app.sh` copies `Resources/AppIcon.icns` into the bundle; `Info.plist` names it with
`CFBundleIconFile`. The script needs Google Chrome (headless rasteriser) and `iconutil`.

## Why full bleed

On macOS 26 an `.icns` drawn in the classic shape (rounded rectangle inside a 100px margin) is
shrunk onto a grey plate, even in the default icon appearance. A full-bleed opaque square is
masked by the system like a native icon. Checked 2026-10-10 on macOS 26.6. The cost: macOS 15
does not mask `.icns`, so on Sequoia the icon shows as a plain square.

## Follow-up

The complete fix is an Icon Composer `.icon` with three layers: the paper plate, the `#` with the
caret and heading bar, and the body lines. `xcrun actool` compiles it into `Assets.car`, named by
`CFBundleIconName`, with a classic-shape `.icns` kept for macOS 15. That gives Liquid Glass, the
Clear and Tinted appearances, and a rounded icon on Sequoia. It needs Xcode 26, which this Mac
does not have.
