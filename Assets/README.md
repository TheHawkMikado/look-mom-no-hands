# Brand assets

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="png/lockup-dark@2x.png">
  <img src="png/lockup-light@2x.png" alt="Look Ma, No Hands" width="420">
</picture>

## The mark

Five capsules: four fingers rising in an arc, plus a thumb tilted off to the
left. It reads as a **raised hand** and as an **audio level meter** at the same
time — which is the product in one shape, and the joke in the name.

The SVGs are the masters; everything in `png/` is generated. **Never redraw the
mark** — the five paths are identical in every file, so edit `mark.svg` and copy
the geometry across. That includes the Swift copy in
[BrandMark.swift](../Sources/LookMomNoHands/BrandMark.swift), which draws the
live menu-bar glyph from the same coordinates.

| File | Use |
|---|---|
| [icon.svg](icon.svg) | macOS app icon master, 1024×1024 on Apple's 824px superellipse body |
| [mark.svg](mark.svg) | Bare mark, `currentColor`, for inline/web use |
| [menubar-template.svg](menubar-template.svg) | Menu-bar template image — thinner strokes so the bars separate at 16–18pt |
| [lockup.svg](lockup.svg) | Mark + wordmark, `currentColor`, for the README / site / DMG |
| [AppIcon.icns](AppIcon.icns) | Built by `Scripts/render_icon.sh`, copied into the bundle by `assemble_app` |
| `png/` | Rasterised exports — icon 16→1024, menu-bar @1x/@2x, and the lockup in `-light` (black ink, for light backgrounds) and `-dark` (white ink) at @1x/@2x |

## Colour

| | Hex | Where |
|---|---|---|
| Indigo | `#5B4CFF` | Icon gradient, top-left |
| Violet | `#8B3DFB` | Icon gradient, midpoint |
| Magenta | `#B23BF0` | Icon gradient, bottom-right |
| Bar white | `#FFFFFF` → `#EDE7FF` | The five capsules, top to bottom |

The gradient runs top-left → bottom-right at 45°. On anything that isn't the app
icon the mark is monochrome: full-strength foreground, no gradient.

## Rules that matter

- **Clear space** — keep at least one bar-width (76 units, ½ the mark's height ÷ 5)
  clear on every side of the mark and the lockup.
- **Minimum size** — mark 16px tall; lockup 120px wide. Below that use the mark alone.
- **The menu-bar asset stays pure black on transparent.** macOS recolours a template
  image for light/dark menu bars and for the highlighted state; giving it a colour
  or a gradient breaks that.
- **Don't** re-space the bars, straighten the thumb, add an outline, or set the mark
  on a busy photo. The thumb tilt is the whole idea.

## Regenerating

```sh
./Scripts/render_icon.sh     # SVG masters -> AppIcon.icns + png/
```

No Homebrew needed: [Scripts/svg2png.swift](../Scripts/svg2png.swift) rasterises
through the WebKit that ships with macOS, `sips` resamples, `iconutil` packs the
`.icns`. The outputs are committed so an ordinary build never rasterises anything.

## Wordmark

Live text in the system UI font (SF Pro Display Semibold, `letter-spacing: -3`
at 128px). It renders as designed on Apple platforms and falls back to
Helvetica/Arial elsewhere. If you ever need it pixel-identical off-Apple — print,
Windows, a design tool — convert the text to outlines first.
