# How seal.png was struck

`seal.png` is the canonical Ministry seal, lifted from the estate's own struck
artwork rather than re-rendered here.

Re-rendering the SVG locally does not work. The seal's ring text is Zilla Slab
on a `textPath`, and under any wider fallback the string overruns the path and
SVG **silently drops the characters that fall off each end** — `rsvg-convert`
with Georgia produces a seal with no ring text at all, and no warning. Zilla
Slab is not installed on this machine, and shipping it here would mean
redistributing a font this repo has no business carrying.

So the plate comes from `eve-online-ministry/docs/wallpapers/`, which the
estate strikes through Playwright with the real face loaded:

```sh
W=…/eve-online-ministry/docs/wallpapers/pantoscope-macbook-14.png
ffmpeg -y -i "$W" -f lavfi -i "color=c=0xC15F3C:s=512x512" -filter_complex \
"[0:v]crop=700:700:1169:362,scale=512:512,format=gray,\
lutyuv=y='clip((val-26)*255/94,0,255)'[a];[1:v]format=rgba[c];[c][a]alphamerge,\
format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':\
a='if(lte(hypot(X-256,Y-256),247),alpha(X,Y),0)'" \
-frames:v 1 Resources/seal.png
```

The circular mask at the end is not decoration. The pendant hangs directly
below the disc at bottom centre, so any square crop with enough padding to keep
the outer ring off the frame edge also catches the stem. Clipping to the disc
removes it without pulling the ring in.

The alpha is derived from the plate's luminance, so the stamp grain survives and
the wallpaper's ground does not. The disc only — the pendant is cropped away,
because in a fixed-height row it would force the disc smaller than it can afford
to be.

`seal.svg` is kept beside it as the source of record. It is not what produces
the PNG.
