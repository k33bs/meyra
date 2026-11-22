# net files (version 1)

weights of the small nets the enhance setting runs. `src/nets.mm` reads them, `tools/netref.py` is the reference,
`tools/mpv2net.py` made the ones here from mpv shaders.

one plain text file per network in this folder. the app reads every `*.net` in that
folder at start (sorted by file name), turns each into metal shader passes itself, and offers them as
`enhance` 1, 2, 3 ... in that order. no code change, no build step: drop the file in, `make`, done.
name files so they sort where you want them (`1-fsrcnnx.net`, `2-artcnn-c4f16.net`, `3-yours.net`).

## what the net sees and returns

- input `y`: ONE channel, luma of the picture at source size (1920x1080), float 0..1.
  `y = 0.2126 r + 0.7152 g + 0.0722 b` of the gamma (not linear) rgb after levels, so black is 0.0 and white
  1.0 whatever range the console sends. 8 bit source, so steps of 1/255. at the default placement the picture
  has been through dither removal first (game dither of 1-2 levels mostly flattened); with placement 1 it is raw.
- output: ONE channel, luma at exactly 2x (or at 1x, see below), same range, clamped to 0..1 by the app.
  the app does the colour: rgb is scaled 2x bilinear and the luma of that is replaced by the net's
  (`rgb_out = rgb_bilinear + (y_net - y_of_rgb_bilinear)`).
- sampling grid: output pixel (2x+dx, 2y+dy) belongs to source pixel (x, y), i.e. the usual pixel shuffle
  layout, no half pixel shift. train with LR = area/box or bicubic downscale of HR without a shift.
- the net runs on every frame, real and generated, 60 times a second. there is no temporal input.

## what a net may consist of

a list of layers, each one

    out = act( bias + conv_k( sum of `in` layers ) + sum of `add` layers )

- conv: k = 1, 3, 5 or 7, stride 1, cross-correlation as in pytorch `Conv2d`, bias always present
- padding: EDGE REPLICATION (`padding_mode='replicate'`), not zeros. a net trained with zero padding still
  runs, it is only a little off in the outer k/2 pixels
- features per layer: 1..32. 8-16 is the intended range (cost grows with in x out)
- act: `none`, `relu`, or `prelu` (one negative slope per output feature). leaky relu = prelu with equal slopes
- `in`: one or more earlier layers (or `y`) with the same feature count, summed before the conv. `y` can
  only be the single input of a layer (not in a sum)
- `add`: zero or more earlier layers with `out` features, added after the conv and before the activation
  (residual / skip connections). `y` is not allowed here
- the last step is depth-to-space 2x from a layer with exactly 4 features, pytorch `PixelShuffle(2)` order:
  feature `dy*2+dx` becomes output pixel (2x+dx, 2y+dy)
- or, for a net that only restores (1x): the last layer has exactly 1 feature and there is no depth-to-space.
  the output is the same size as the input. with `base nearest` (or `bilinear`, the same thing here) the input
  `y` is added to it. such a net leaves the upscaler chosen in the app to do its job after it
- optional base for a residual net: `base nearest` adds the source pixel's `y` to its four outputs,
  `base bilinear` adds the bilinear 2x upscale of `y` (align_corners=False). default `base none`:
  the net's output is the picture
- not available: concat, stride, dilation, groups/depthwise, transposed conv, batchnorm (fold it), sigmoid/tanh,
  rgb in or out, scales other than 2

intermediate values are stored as 16 bit floats (rgba16float textures): about 3 decimal digits, max 65504.
keep activations in a sane range (within +-100 or so), which trained nets do anyway. maths inside a layer is
32 bit float.

## file syntax

tokens separated by any whitespace (line breaks are free), `#` starts a comment to the end of the line.
put the licence / origin of the weights in comments at the top, the app keeps the file as is in its bundle.

    # licence, where the weights come from
    meyra-net 1
    name Short Name For The Menu
    layer ID conv k=K in=ID[+ID...] out=N [add=ID[+ID...]] act=none|relu|prelu
    w  <N * IN * K * K floats>
    b  <N floats>
    a  <N floats>                 # only with act=prelu
    layer ...
    out ID [base none|nearest|bilinear]

- ID: letters, digits, `_`. `y` is the input. a layer can only use layers defined above it
- `name` runs to the end of its line
- `w` order: `[out][in][ky][kx]`, exactly `conv.weight.flatten()` of a pytorch `Conv2d(IN, N, K)`.
  tap (ky, kx) reads the pixel at (y + ky - K/2, x + kx - K/2)
- `b`: `conv.bias`. `a`: `prelu.weight` (N values; repeat it N times if you trained a single shared slope)
- floats in any form python prints (`0.1`, `-1.5e-3`)
- `out` comes last

example exporter (pytorch):

    def layer(f, name, conv, src, act='none', prelu=None, add=None):
        k, n = conv.kernel_size[0], conv.out_channels
        f.write(f"layer {name} conv k={k} in={src} out={n}" + (f" add={add}" if add else "") + f" act={act}\n")
        f.write("w " + " ".join(f"{v:.8g}" for v in conv.weight.detach().flatten().tolist()) + "\n")
        f.write("b " + " ".join(f"{v:.8g}" for v in conv.bias.detach().tolist()) + "\n")
        if act == 'prelu':
            a = prelu.weight.detach().flatten().tolist()
            f.write("a " + " ".join(f"{v:.8g}" for v in (a * n if len(a) == 1 else a)) + "\n")

    with open("3-mine.net", "w") as f:
        f.write("# own net, trained on ...\nmeyra-net 1\nname Mine\n")
        layer(f, "c0", m.c0, "y", "prelu", m.p0)
        layer(f, "c1", m.c1, "c0", "prelu", m.p1)
        layer(f, "c2", m.c2, "c1", "prelu", m.p2, add="c0")
        layer(f, "c3", m.c3, "c2")            # 4 features
        f.write("out c3 base nearest\n")

## checking an export

`tools/netref.py FILE.net IN.gray W H OUT.gray` (in the app tree, plain python, no numpy, slow: use a small
crop) runs a net file on raw 8 bit luma and writes the 2x result. it is the definition the app's passes are
checked against. compare it with your framework's output for the same crop; they should agree to ~1/255
away from the border (and at the border too if you trained with replicate padding).

## cost, for sizing

each layer is one fragment pass at source size over 1920x1080, all its outputs written at once.
cost is roughly taps x in x out per pixel. the nets shipped first: (fsrcnnx 8-0-4-1: 5x5 1->8, four 3x3 8->8, 1x1 8->8, 3x3 8->4; artcnn c4f16: 3x3 1->16, five 3x3
16->16, 3x3 16->4). budget: the whole frame should stay well under ~8 ms on an m4 max with frame generation
running, less is better.

## how it is used (so you know what to train for)

- `enhance N` picks the net, 0 = off. separate from `upscale`: it also runs when the window is the size of
  the source. the 2x output is then filtered down to the window (`enhanceDown`: 0 area filter, 1 lanczos); at 2x
  and above it is used as it is. so the net is judged mostly AFTER a downscale to 1x-1.33x: what survives is cleaner edges, less
  noise, restored contrast of fine detail, not extra pixels.
- sharpening (cas, default 0.6) still runs after it. a net that already sharpens hard will be oversharp.
- placement (`enhanceAt`): 0 after dither removal (default), 1 before it, 2 after the upscaler.
