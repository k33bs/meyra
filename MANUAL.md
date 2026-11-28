<div align="center">

<h1>meyra manual</h1>

the full reference: every key and switch, what each does and costs, the measured numbers and their caveats.

[README](README.md) · [install](#install) · [presets](#presets) · [keys](#keys) ·
[every switch](#every-switch-by-menu) · [changelog](CHANGELOG.md)

</div>

meyra shows a game console on a mac through an hdmi capture card. little delay, a cleaner and sharper picture, and
generated in-between frames for 30 fps games.

you have a console, a capture card and a mac, and you want to play in a window without the picture trailing
behind your thumbs. that is the whole job. a frame is drawn as soon as it arrives. on the way it loses the game's
dither, gets upscaled and sharpened, and where the game only manages 30, every repeated frame is swapped for one
made in between, so it moves like 60. free, gpl. needs apple silicon and macos 14 or later, macos 26 for the
generated frames.

new here: the readme has the short way in. the same steps in full are here: [install](#install), then
[the first five minutes](#the-first-five-minutes).

## contents

- start here: [what it does](#what-it-does) · [install](#install) · [the first five minutes](#the-first-five-minutes) ·
  [what you need](#what-you-need) · [capture devices and vendor drivers](#capture-devices-and-vendor-drivers)
- day to day: [presets](#presets) · [keys](#keys) · [every switch by menu](#every-switch-by-menu)
- the long read: [what each thing does](#what-each-thing-does) ·
  [the gta6 weights and the others](#the-gta6-weights-and-the-others)
- upkeep: [updates](#updates) · [when something is off](#when-something-is-off) · [debug report](#debug-report) ·
  [known limits](#known-limits)
- under the hood: [building](#building) · [development](#development) · [some numbers](#some-numbers)

## what it does

- **low delay.** every frame is drawn as soon as it arrives. about 25 ms from capture to screen with frame
  generation off.
- **frame generation.** a 30 fps game arrives as 60 hz with every frame sent twice. meyra swaps each repeat for a
  frame generated between the two real ones (apple's low latency frame interpolator), so it moves like 60 fps.
  costs about 30 ms of extra delay.
- **cleaner picture.** removes the fine dither pattern many games add, upscales to the window with metalfx (or
  an edge-aware shader, or apple super resolution) and sharpens brightness only, with a limit so there are no halos.
- **correct levels.** video range and full range are detected on their own.
- **sound in step.** the source's audio is played delayed to match the picture.
- **even motion.** switches the display, while it runs, to a refresh rate the source divides into evenly.
- **a normal window.** discord, obs and screen sharing can pick it as a source, picture and sound.

the way a frame goes through it:

```
console --hdmi--> capture card --> real frames        a 30 fps game sends each one twice
                                       |
                                [noise filter]
                                       |
                               frame generation       each repeat becomes a frame made in between
                                       |
   levels -> dither removal -> [enhance net] -> upscale -> [look] -> sharpen -> [grain]
                                       |
                                    screen            the sound is held back to land with it
```

steps in brackets are off until you turn them on. the generator works on the frames before levels and the rest
of that row; real and generated frames then both go through it. the status overlay (H) shows the same thing live: what
the frames of the last second really went through, in the order it happened.

## install

1. grab `Meyra-vX.Y.Z.zip` from the [releases page](https://github.com/k33bs/meyra/releases).
2. unzip it and drag `Meyra.app` into applications.
3. open it. macos will refuse the first time, because the app is not signed with an apple developer id. go to
   system settings > privacy & security, scroll down and click "open anyway", then confirm.
4. plug in the capture card with the console on. meyra picks it up, or asks which one if there are several.
5. on the standard capture route macos asks for camera and microphone access. say yes to both, a capture card
   counts as a camera and its sound as a microphone. the blackmagic driver route asks for nothing.

after that it updates itself, see [updates](#updates). or build it yourself, see [building](#building).

the short form, as the release notes have it: unzip, drag `Meyra.app` to applications, then system settings >
privacy & security > "open anyway" on first launch.

## the first five minutes

console on, capture card in, meyra open. on first launch meyra uses the capture device if there is exactly one,
otherwise it asks. it remembers the source and all settings. everything is in the menu bar, and the single keys
work while the picture has focus. you do not have to read any further than this table:

| key | what it does | why you want it |
|---|---|---|
| H | status overlay: compact, with the switches, off | says what is running, how late it is, and which key changes what |
| 1 … 9, 0 | presets | a whole set of picture and motion switches at once. 1 is standard, which is also how meyra starts out |
| / | compare | the original against the finished picture, so you can see whether any of this does something |
| Z | plain passthrough | all processing off, for when you just want the signal |
| G | frame generation | off for games where reaction time matters most. 3 is the preset for that |
| F | full screen | esc leaves it. on a variable refresh screen full screen also means much less delay |
| W | next window size | 720p up to whatever fits the screen |
| space | freeze | holds the newest real frame while you flip switches on it |
| tab | record | what is on screen goes to a .mov in movies/meyra |
| ; ' | audio 5 ms earlier / later | for when lips and voices are off |

> [!TIP]
> after every key one line says what is set now and what that does, so pressing things and reading along is a fair
> way to learn the rest. the menu items carry the same texts as tooltips.

then, as the mood takes you:

- 30 fps game, hud shimmers in motion: try preset 4 (smooth), or see [huds and still things](#huds-and-still-things).
- every ms counts: preset 3 (fastest), full screen on a variable refresh screen, and
  [the screen and the last few ms](#the-screen-and-the-last-few-ms).
- playing gta vi: presets 8, 9 and 0 use a net trained on that game and nothing else.
- blacks look grey, shadows look crushed, or something else is plainly wrong:
  [when something is off](#when-something-is-off).

## what you need

| what | needs |
|---|---|
| meyra | a mac with apple silicon, macos 14 or later |
| frame generation | macos 26 or later. without it the menu item is greyed out, the rest works |
| apple super resolution | macos 26 or later, same as above |
| a capture device | any hdmi capture card macos can see |
| building | xcode command line tools (`xcode-select --install`), nothing else |

## capture devices and vendor drivers

every capture device works through the system's own capture interface, nothing to install. macos asks for
camera and microphone access the first time, because that is what capture devices count as.

a **vendor driver** is an optional second route to one maker's devices, through that maker's own sdk. worth
having when the sdk is quicker, keeps sound in step, or needs no permissions. meyra ships one, for blackmagic
decklink and ultrastudio devices. it is only used for those, and only when blackmagic's desktop video software
is installed. such a device then shows up twice in the source menu:

- `UltraStudio Recorder 3G (Blackmagic driver)`: sound in step with the picture, no permissions.
- `Blackmagic UltraStudio Recorder 3G (standard capture)`: like any other card. its sound arrives late on this
  route and plays about 50 ms behind the picture.

> [!NOTE]
> tested with an ultrastudio recorder 3g over hdmi at 1080p60. usb capture cards use the standard route and have
> not been tested yet.

got a card from another maker with its own sdk? see
[adding a driver for another maker](#adding-a-driver-for-another-maker).

source > format lists what the device offers. meyra opens 1080p by itself even where the device offers more; that
entry says (default) where system capture offers more than one format, the larger ones sit above it.

source > audio input: a card's sound is a separate audio device to macos, often with another name ("usb3 digital
audio" for "usb3 video"). automatic looks for it in this order and takes the first hit: the device macos links to the
card, the same name, the same id up to its last colon (blackmagic), the same usb vendor and product, the card's name
inside the audio device's id. never a microphone by default, never the default input. a camera (built-in, iphone, a
usb webcam with camera or webcam in its name) gets none on automatic: its own microphone out of the speakers feeds
back. a webcam without such a word is taken for a card, see [known limits](#known-limits). two devices that match
under one rule (two alike cards plugged in) go on to the later rules: the one left wins (two alike blackmagic units
told apart by the id). none left gives none, which is which cannot be told; the overlay's audio row then says "no
audio input: choose one in source > audio input". with an input open it names it and how it was found, next to the
output: "in step with the picture (input: usb3 digital audio, auto: same usb vendor:product; output: …)". the start
line in the log and the debug report say the same, or why none. `--list-devices` prints what automatic takes for each
device.

### too few frames from the card

cheap usb cards often cannot push uncompressed 1080p60 through: the format says 60, 20 or 30 arrive. meyra watches
for it on the standard capture route: under 70 % of the format's rate for 3 s, while the gpu keeps up and macos itself
drops next to nothing, means the card sends too few. then the overlay gets an amber line under the numbers, "the card
delivers 20 of 60 frames a second in this format: try ...", with what to try; with the overlay off the same text shows
once as a hint. the motion line says "the card sends only 20 of 60 frames a second" and cadence "(too few frames from
the card)". it clears after 2 s back at the rate.

- cameras are not watched: they lower their rate in low light.
- a card whose own timestamps come evenly at a rate games send (24, 25, 30, 48, 50 and their 1000/1001 kin) is passing
  the signal's own rate through: no hint, one line in the log says so. an even 20 of 60, or 60 with gaps, still counts.
- what macos really runs is read back after the start and again a second later: size, pixel layout and rate. if it
  is not what was asked, meyra sets it once more (up to three tries; a device that runs what was asked gets no second
  call), and if it still differs the hint says "macos runs the card at ..., not the chosen ...: choose the format
  again, and if it stays send help > copy debug report". the log has a line for each check.
- every second the log gets a `capture` line: frames from the device, the spacing of its own timestamps, what
  avfoundation dropped and why (late, out of buffers, discontinuity, other), buffers without a picture, and the format
  macos runs. the overlay's now column shows "macos runs ..., asked ..." and "dropped ..." only when there is
  something to show.

- **layout** (experimental): where the format in use also comes compressed, source > format gets a layout section:
  **uncompressed (least delay)**, what meyra always used, or **compressed (mjpeg)**: the card sends jpeg pictures and
  the mac unpacks them. a little more delay, and some usb cards only reach their format's full frame rate this way.
  kept per source, also in source > choose source (the layout row, "automatic" and grey where there is nothing to
  choose). choosing one restarts the source. not tried yet on a card that offers it: how much delay the unpacking adds
  is open. if black looks dark grey (the overlay's darkest about 30), the card packs video levels as full range jpeg:
  the levels switch cannot undo that, uncompressed or a lower format can. a repeat can unpack a little differently, so
  with compressed and tolerant repeats off, "source sends no repeated frames" points at tolerant repeats (P).
- then a lower format, or a usb 3 port on the mac itself, no hub or dock.
- `--list-devices` shows every layout the device reports per size and rate, see
  [development](#development). for a bug report the [debug report](#debug-report) is better: it has all of it and
  more, without ids.

## presets

ten sets of picture and motion switches on the number keys. each starts from the same plain base, so a key always
gives the same thing; levels, colour, audio, window, display, gpu awake and the side bars are left alone. vsync is
part of a preset: every built-in one turns it on, one of your own sets it as you saved it. the output
rate goes off, and its own switches (blend, real frames, ride out, even out, enhance made frames) and the six newer
block matching switches go back to their defaults; a preset of your own saved before v0.6.0 does the same, as it did
not know them. shift + number saves the switches as they are over that slot, and again overwrites what you saved there. presets > remove my preset brings
that slot's built-in one back, restore built-in presets all of them. the overlay shows which one is on, and
"(changed)" once one of its switches is.

| key | preset | what it is | delay |
|---|---|---|---|
| <kbd>1</kbd> | standard | dither removal, metalfx, medium sharpening, apple's frame generation on the tick | 31.4 |
| <kbd>2</kbd> | untouched | plain passthrough | |
| <kbd>3</kbd> | fastest | no generated frames, light sharpening | 0.6 |
| <kbd>4</kbd> | smooth | soft still rule, hud lock, better cut test | 31.5 |
| <kbd>5</kbd> | smooth, less delay | the same, early schedule | 28.9 |
| <kbd>6</kbd> | second generator | the second generator at 480 lines | 31.5 |
| <kbd>7</kbd> | second generator, less delay | the same, early schedule | 26.8 |
| <kbd>8</kbd> | GTA6 clean | a net trained on gta vi on real frames, light sharpening, hud lock | 31.6 |
| <kbd>9</kbd> | GTA6 clean, second generator | the net and the second generator, early schedule | 28.9 |
| <kbd>0</kbd> | GTA6 everything | the net and most experiments at once, on the tick | 31.6 |

> [!NOTE]
> delay: ms from a real frame's arrival to its present call, on an m4 max with a recorded clip in a 2450x1378 window at
> 100 hz, the median of the runs. the capture card and the screen add their own. now and then one of the generating
> presets has a short spell of late generated frames, then the real frame stays up. 6, 7 and 9 need the second
> generator's files. 8, 9 and 0 use a net trained on gta vi, on other games it may well do worse.

## keys

work while the picture has focus. the overlay shows them too, next to what each is set to.

| key | picture |
|---|---|
| <kbd>Z</kbd> | plain passthrough: all processing off |
| <kbd>R</kbd> | levels: automatic, video range, full range |
| <kbd>C</kbd> | colour: bt.709, srgb, the screen's own |
| <kbd>B</kbd> | dither removal |
| <kbd>D</kbd> | noise filter |
| <kbd>N</kbd> | next enhance net, then off. nets of over 64 passes (the still-picture one) are menu only |
| <kbd>O</kbd> | enhance on real frames only (experimental) |
| <kbd>Y</kbd> | steady enhance (experimental) |
| <kbd>M</kbd> | next upscaler, hashed filters included. apple super resolution only where the mac has it |
| <kbd>U</kbd> | supersample (experimental) |
| <kbd>[</kbd> <kbd>]</kbd> | sharpening down / up |
| <kbd>.</kbd> | look: off, mild, middle, strong (experimental) |

| key | motion |
|---|---|
| <kbd>G</kbd> | frame generation |
| <kbd>I</kbd> | next frame generator: apple's, second at 480 lines, second at 720 lines, block matching. without the second generator's files it is one stop, where return downloads them |
| <kbd>return</kbd> | download the second generator, only while it is chosen and not installed |
| <kbd>E</kbd> | frame schedule: early or on the tick |
| <kbd>S</kbd> | next rule for still areas in generated frames |
| <kbd>T</kbd> | generate at: full size, 864, 768, 720 lines |
| <kbd>Q</kbd> | mark a hud area: the next drag on the picture always shows the real frame (esc cancels) |
| <kbd>L</kbd> | hud lock (experimental) |
| <kbd>K</kbd> | cut test (experimental) |
| <kbd>P</kbd> | tolerant repeats (experimental) |
| <kbd>J</kbd> | capture clock (experimental) |
| <kbd>V</kbd> | vsync |

| key | comparing, presets, window, sound |
|---|---|
| <kbd>space</kbd> | freeze the picture on the newest real frame, every switch but the noise filter still acts on it |
| <kbd>tab</kbd> | record what is on screen: start, stop. while the last 30 seconds are kept: save them |
| <kbd>shift</kbd> + <kbd>tab</kbd> | keep the last 30 seconds instead of recording from start to stop, and back |
| <kbd>/</kbd> | compare: original against final cut left / right, above / below, diagonal, side by side, stacked, then every stage, off (shift + / goes back) |
| <kbd>1</kbd> … <kbd>9</kbd>, <kbd>0</kbd> | presets: a whole set of picture and motion switches at once |
| <kbd>shift</kbd> + number | save the switches as they are now over that preset (again to overwrite, presets > remove my preset undoes it) |
| <kbd>H</kbd> | status overlay: compact, with the switches, off |
| <kbd>F</kbd> | full screen (esc leaves it) |
| <kbd>W</kbd> | next window size, in full screen the next size the picture is made at |
| <kbd>X</kbd> | full screen keeps the window's resolution |
| <kbd>A</kbd> | audio |
| <kbd>;</kbd> <kbd>'</kbd> | audio 5 ms earlier / later |
| <kbd>⌘S</kbd> | save a snapshot to pictures |
| <kbd>⌘R</kbd> | restart the source |
| <kbd>⌘0</kbd> | window at actual size |

## every switch by menu

the same switches again, by where they sit in the menu bar, with their defaults. the ones without a key are
menu only.

| menu | setting | key | default |
|---|---|---|---|
| source | device, input or format, audio input, restart source | ⌘R | |
| source | format > layout (experimental, only where the format offers both): uncompressed (least delay), compressed (mjpeg) | | uncompressed |
| source | save snapshot (png, to pictures) | ⌘S | |
| picture | levels: automatic, video range, full range | R | automatic |
| picture | colour: bt.709, srgb, the screen's own | C | bt.709 |
| picture | noise filter (apple's temporal one, real frames only, ~10 ms a frame) | D | off |
| picture | stabilise (experimental): the frame before mixed in along the motion, real frames only | | off |
| picture | dither removal | B | on |
| picture | upscaling: plain, metalfx, edge-aware (fsr 1 or sgsr 1), hashed filters (experimental), apple super resolution | M | metalfx |
| picture | enhance (experimental): off, or a small neural net on every frame at any window size | N | off |
| picture | enhance: half precision (faster) | | off |
| picture | sharpening: off, low, medium, high | ] [ | medium |
| picture | enhance real frames only, steady enhance, supersample (experimental) | O Y U | off |
| picture | look (experimental): off, mild, middle, strong | . | off |
| picture | grain (experimental): off, light, medium, strong, full | | off |
| picture | side bars (experimental): off, grey, glow, glow with past picture | | off |
| picture | side bars: very dark, dark, medium, light (grey and glow); less soft, soft, very soft (glow) | | dark, soft |
| picture | side bars > fill the window with letterboxed pictures (experimental) | | off |
| picture | side bars > no stretch, stretch a third, stretch two thirds, stretch to fill (experimental) | | no stretch |
| picture | plain passthrough (all processing off, every frame shown as it came) | Z | off |
| motion | frame generation | G | on |
| motion | frame schedule: early, on the tick | E | on the tick |
| motion | still areas in generated frames: exact match only, soft, by motion against contrast (two kinds) | S | exact match only |
| motion | generate at: full size, 1536×864, 1344×768, 1280×720 (apple's interpolator: smaller is faster and softer) | T | full size |
| motion | generated frame deadline: by the slowest, by the usual (early schedule) | | by the slowest |
| motion | show late generated frames a refresh later | | off |
| motion | frame generator (experimental): apple's interpolator, a second one from files you install, at 480 or 720 lines, or block matching (no files) | I | apple's |
| motion | frame generator > find the whole picture's shift first, take one side where the frames disagree (block matching, experimental) | | off |
| motion | frame generator > find small fast things, go soft where the match is bad, take one side, steady, keep the followed character whole, show a real frame across a cut, made frames as sharp as real ones (block matching, experimental) | | off |
| motion | output rate (experimental): off, every signal tick, every screen refresh, fixed 30 / 50 / 60 fps, times 2 / 3 / 4, times 2 following the gap, source rate (real frames only) | | off |
| motion | output rate > blend in-betweens instead of generating (experimental) | | off |
| motion | output rate > real frames: fewest (evenest motion), some, more, all (experimental) | | some |
| motion | output rate > ride out dropped frames: off, one tick (+17 ms), two ticks (+33 ms), three ticks (+50 ms) (experimental) | | off |
| motion | output rate > even out the game's late frames, enhance the made frames too (experimental) | | off |
| motion | hud lock (experimental): what has stood still for a second keeps its real pixels in generated frames | L | off |
| motion | mark hud area, clear hud areas, show hud areas: up to 8 rectangles that always show the real frame in generated ones | Q | none |
| motion | cut test (experimental): scene cuts told by a coarse picture and its histogram, flashes let through | K | off |
| motion | tolerant repeats (experimental): a repeated frame may come back a few levels off (noisy usb cards) | P | off |
| motion | capture clock (experimental): presents timed from the capture timestamps, not from arrival | J | off |
| motion | skip only after a lasting backlog (experimental): a frame is skipped to catch up only after half a second behind | | off |
| motion | match display refresh: off, automatic, source rate | | automatic |
| audio | play audio, earlier / later by 5 ms | A, ; ' | on, 0 |
| window | show status overlay | H | on |
| window | enter full screen, actual size | F, ⌘0 | |
| window | window size: next size (720p, 900p, 1080p, 1440p, 2160p, whatever fits the screen) | W | |
| window | full screen keeps the window's resolution (scaled to the screen, the ratio stays) | X | off |
| window | freeze picture | space | off |
| window | compare: off, original against final (left / right, above / below, diagonal, side by side, stacked), every stage | / | off |
| recording | record what is on screen to a .mov, or keep the last 30 seconds and save them when asked | tab, shift + tab | off |
| recording | recording menu: size (as shown, 2160p, 1440p, 1080p, 720p), bitrate (by size, or 10 to 100 mbit), overlay and hint lines in the file, open recordings folder | | at most 1080p, by size, not in the file |
| presets | ten sets of switches, save the current ones over one, remove one of yours, restore the built-in ones | 1 … 9, 0 | |
| meyra | vsync | V | on |
| meyra | take the screen buffer late, two screen buffers instead of three (experimental) | | off |
| meyra | game mode in full screen | | on |
| meyra | keep the gpu awake (uses more power) | | off |
| meyra | turn meyra off: the capture device is let go and nothing is drawn, generated or played. the window and the settings stay, the same item turns it on again | | |
| meyra | check for updates, at launch, revert to previous version | | at launch: on |
| help | keyboard shortcuts, copy debug report, common problems and fixes (the readme's [help](README.md#help) in the browser), discord | | |

## what each thing does

the long read. one entry per switch: what it does, what it costs, and where it was measured, what came out.
grouped by what you are trying to fix, not by menu.

- [picture basics](#picture-basics)
- [upscaling](#upscaling)
- [enhance nets](#enhance-nets)
- [frame generation](#frame-generation)
- [output rate](#output-rate)
- [huds and still things](#huds-and-still-things)
- [cuts, repeats and timing](#cuts-repeats-and-timing)
- [the screen and the last few ms](#the-screen-and-the-last-few-ms)
- [sound](#sound)
- [window, overlay and comparing](#window-overlay-and-comparing)
- [side bars](#side-bars)
- [recording](#recording)

### picture basics

the plain end of the chain: getting levels and colour right, cleaning up before the picture is made bigger, and
what goes on after.

- **levels**: if blacks look grey or shadows look crushed, pick the range by hand. the overlay shows the darkest
  value seen: 16 on a black picture means the source sends video range.
- **colour**: how the picture's colours are handed to macos. bt.709 is what the source says they are and looks
  the same on every screen, a little flat. srgb has the contrast of a tv. the screen's own skips colour
  management: most saturated, and different on each screen.
- **dither removal**: many games add a fine checker or noise pattern to hide banding. upscaled and sharpened it
  turns into grain. this takes it out before anything else touches the picture. leave it on unless a game
  looks smeared in flat areas.
- **noise filter**: apple's temporal noise filter on the real frames. it compares each frame with the ones
  before it and averages out what flickers. costs about 10 ms a frame and is hard to see on a clean signal.
  worth trying on a grainy game, off otherwise.
- **stabilise** (experimental, off): the frame before, moved along the picture's motion and held to what is around
  each pixel now, is mixed in a little (at most 0.3 of each pixel). meant to steady edges, the effect is
  small. at source size after dither removal. it steps aside while frames are generated: only the real ones would
  be steadied. the motion comes from a block search in the shaders on a quarter size copy.
- **sharpening**: brightness only, colour is left alone, and limited so edges get no bright halos. off, low,
  medium, high. with enhance or metalfx on, go lower.
- **look** (experimental, off): a tone curve and one factor on the colours, put on last, before sharpening. fitted on
  before / after videos of gta vi with the dlss 5 look. most of what makes that look is such a curve plus new
  lighting; the lighting cannot be had from a video signal, so only the curve is here. it changes brightness and
  colour, it adds no detail. **mild** is nearly the picture as it came with lower highlights and weaker colours,
  **strong** was fitted on one dark cutscene and makes daylight dull, **middle** is the mean of the two. fitted on
  one game, on uploads of a modded version of it: expect it to be wrong elsewhere.
- **grain** (experimental, off): fine grain added in the last pass, strongest in dark and mid tones, none in black and
  white. meant to cover the plastic look of areas dither removal, a net or a scaler cleaned out. light, medium, strong, full
  (0.25 to 1). off in plain passthrough.
- **plain passthrough**: everything off, every frame shown as it came, repeats included. for comparing, and
  for when you just want the signal. one thing is still done: when the display's queue has backed up (after the
  display changed mode, after a stall), one exact repeat is left out to clear a place, as with frame generation
  off. it used to be exempt and then ran two to three refreshes behind for good.
- **snapshot**: one processed frame as png in pictures, without the overlay.

### upscaling

several ways from the source's size to the window's. none of them adds detail; they differ in what they do to
edges and to grain.

- **upscaling** is how the picture gets from the source's size to the window's. it only runs when the window is
  larger than the source.
  - **plain**: bilinear. soft, free, changes nothing else.
  - **metalfx**: apple's spatial upscaler. sharpest, but it also sharpens grain and whatever dither is left.
  - **edge-aware**, **hashed filters** and **apple super resolution**: see below.
- **edge-aware (fsr 1)**: the easu pass of amd's fidelityfx super resolution 1 as a shader, then the usual
  sharpening. costs nothing worth measuring and runs with frame generation. sits between plain and metalfx:
  cleaner edges than plain, less grain and crunch than metalfx.
- **edge-aware (sgsr 1)**: snapdragon game super resolution 1, same idea in one pass. it only touches edges and
  leaves flat areas as plain, so grain stays as it came.
- **hashed filters** (experimental): ravu-lite (r3) in a shader. per pixel one small trained filter, picked by the
  edge under it (angle, strength, coherence), makes the picture at twice the size, which is then brought to the
  window like a net's (area filter or lanczos, the enhance menu's choice). cannot ring, can look softer than metalfx. the table is
  `resources/ravu-lite-r3.txt`, made by `tools/ravu2hash.py`; without a usable one it scales plain and says so in the
  log. supersample is idle with it.
- **apple super resolution**: apple's low latency super resolution scaler instead of metalfx. it only takes up to
  about 1280 pixels a side, so a 1080p frame goes through as two overlapping halves, scaled to 2880×1620, then
  down to the window. cleaner than metalfx (does not pick up dither or grain) but softer, and every frame waits
  for it: about 9 ms at 1080p, and one more cpu core busy. it shares the neural engine with frame generation
  and each slows the other, so with both on they take turns: generate, scale the generated frame, scale the
  next real one. that fits, and costs about 9 ms more delay than metalfx (45 against 36 ms measured). "run with
  frame generation" in the upscaling menu turns that off, then metalfx is used while frame generation is on.
  "pad edges" draws 16 mirrored pixels around each tile, because the scaler rings at the outer edge of what it
  is given. it falls back to metalfx while it starts (a few seconds the first time) and for sizes it cannot
  take, e.g. 4k.
- **supersample** (u, experimental, off): metalfx, fsr 1 or sgsr 1 scale to twice the window and every 2x2 block
  is averaged in linear light. softer, fewer scaler artefacts. idle (the stats line and overlay say why) with plain
  scaling, apple super resolution, a 2x enhance net, or a window no larger than the source.

### enhance nets

small nets run as shader passes, and the switches for how they run. which nets there
are, and how to add one, is in [the gta6 weights and the others](#the-gta6-weights-and-the-others).

- **enhance** (experimental, separate from upscaling): a small convolutional net run as shader passes on every
  frame, real and generated, also when the window is no larger than the source. it works on luma and makes the
  picture at twice the size; at a window of 2x or more that is shown as it is, below that it is filtered down to
  the window (area filter or lanczos, in the menu). while it runs it stands in for the upscaler chosen above;
  apple super resolution steps aside. sharpening still comes after it. every `*.net`
  file in `resources/nets` is one entry, see the readme in that folder for the format, and so is every one in
  `~/Library/Application Support/Meyra/nets/` (one with a name that is there already is left out). what ships is in
  "the gta6 weights and the others" below. on a clean 1080p signal the difference is small. "after dither
  removal" is the normal place; "before dither removal" and "after the upscaler" are there to compare.
- **half precision** (enhance menu, off): the net's layers of up to 24 features do their sums in 16-bit floats
  (the last layer stays in 32-bit). one run a frame it measured 1.2 times quicker on the 4x8 nets, 0.8 to 1.3
  on the 6x16 ones (1.04 in the middle: next to nothing), 1.25 on 8x24; 12x32 nets were slower that way (0.9)
  and are left alone.
  the picture differs from the 32-bit one by one level of 255 at most (two on artcnn ds), 0.05 to 0.2 rms.
  the first use of a net in either precision compiles its shaders; they are compiled layer by layer side by side
  (a 12x32 net: 0.7 s instead of 7) and kept in `~/Library/Caches/<bundle id>/nets` for next time.
- **enhance real frames only** (o, experimental, off): the net runs once per new real frame. what it added to
  luma is kept apart from the picture for the two newest real frames; a frame shown again gets it put back, a
  repeat or a generated frame gets it where its picture still matches the frame it was kept from (3x3, full to
  4.5 of 255, none from 9) and nothing where it moved. the newer real frame is run ahead when it arrives, so a
  generated frame takes the newer frame's first and the older one's where that does not match (net after the
  upscaler: older only). a 30 fps game then costs 30 net runs a second, not 60. the catch: on moving parts
  generated frames go without the net, real ones with.
- **steady enhance** (y, experimental, off): only what the net added is filtered over time, never the picture.
  the change kept from the real frame before is mixed in (weight exp(-dt / 80 ms), 0.66 at 30 fps) where the
  picture still matches there, held inside what the fresh change has in the 3x3 around; where the picture changed
  the fresh change goes out as it is. made for nets that invent detail. a net that mostly removes grain gets
  worse with it: its change follows each frame's grain, and a held one no longer cancels it.

### frame generation

the part that makes 30 move like 60, and the part with the most switches, because a generated frame is a guess
and a guess needs watching.

- **frame generation** only acts when the source repeats frames. 60 fps content is shown as it is. one cpu core
  stays busy while it is on. turn it off for games where reaction time matters most.
- **frame generator** (experimental): who makes the frames in between. **apple's** is the interpolator that comes
  with macos 26: it runs on the neural engine, takes about 11 ms a frame whatever the gpu is doing, and softens
  the picture a little. the **second generator** is a small flow net that runs on the gpu: it works out where
  each pixel moves on a shrunk copy (480 or 720 lines) and then moves and mixes the two real frames at full size,
  so what it gets right stays as sharp as the real frames. **block matching** needs no files and no net: blocks are
  matched on the gpu from coarse to fine and the two real frames are moved and mixed along the vectors.
  - the second generator is not part of meyra. its model is published under cc by-nc 4.0: noncommercial use only, with attribution.
    that does not go together with the gpl, so meyra ships none of it. choose it and it says so in one line: return
    (or the entry under motion > frame generator) fetches it, 1.6 mb, after saying what its licence allows (with a link to it), from
    https://github.com/getflyhigh/flyhigh-engine at one fixed commit, checked against checksums. nothing is fetched
    by itself. by hand works too: `graph.json`, `flyhighfg.json` and `flyhighfg.bin` (from the `models` folder there)
    go into `~/Library/Application Support/Meyra/flyhighfg/`. without them the overlay says "frame generator files
    not installed" and apple's stays in use. files that do not fit are refused with a reason, also in the log;
    choosing the generator again looks at the folder again.
  - **480 lines**: holds up best on fast pans, where apple's blurs foliage and thin things. small still things
    over fast motion (hud icons, overlay text) can double; a still-area rule or hud lock takes care of most.
  - **720 lines**: finer on slow and moderate motion, but its reach is shorter and it breaks up on fast pans.
  - it shares the gpu with scaling, enhance nets and whatever else is running, so its time moves with the load
    and late generated frames are far more likely than with apple's. on a free gpu 6 ms a frame at 480 lines
    against apple's 11 (on the tick the delay comes out the same, on the early schedule about 2 ms less); on a gpu another job
    had busy 24 to 31 ms, and four of five of its frames too late to be shown (the real frame then stays up).
    against real 60 fps frames: 34.0 / 35.7 db (480 / 720) to apple's 32.2 on moderate motion, 29.2 / 29.9 to 30.0
    on fast motion.
    starting it takes a few seconds, the picture is shown without generated frames meanwhile.
  - generate at is for apple's interpolator and is idle while the second generator is in use. still areas, hud
    lock, cut test and both schedules work the same with either. it needs what frame generation needs
    (macos 26, apple silicon). hidden, for tests: `-genModelDir DIR` reads the three files from another folder.
  - **block matching** (experimental): quicker than apple's, searches pans up to about
    160 px a frame, edges of moving things can tear. two switches under motion > frame generator, both off and only
    for it: **find the whole picture's shift first** searches the shift of the whole picture first and uses it as the
    start, for faster pans. **take one side where the frames disagree**: where the frame before and the one after
    disagree about what moves where, the side that fits its surroundings is taken instead of a double image. the
    method follows macframegen and zerofg (see `THIRD_PARTY_NOTICES.md`), the code is meyra's own. generate at is
    idle with it, like with the second generator.
  - six more switches for block matching, all experimental and off, all measured on made-up scenes and recorded
    clips with a test tool, not judged by many eyes yet. none of them acts while blend in-betweens is on (see
    [output rate](#output-rate)):
    - **find small fast things**: the coarse levels of the search lose anything narrower than about two of their cells,
      so a character or a ball moving 30 px a pair or more came out as a ghost or in pieces. each finer level also
      starts from the coarser one's vector before it was smoothed, and where nothing fits, a second look about 64 px
      round the best (at 1080p). the search takes 2.4 to 2.7 ms a pair.
    - **go soft where the match is bad** (output rate only, grey without one): where the frame before and the one after still disagree
      after both are moved into place, the made frame is a cross-fade of the two there, soft or doubled instead of torn.
      not at the picture's border, and less near the real frames. a made frame takes 0.65 to 0.73 ms.
    - **take one side, steady**: where something covers or uncovers what is behind it, the side to show is picked once
      for the pair and smoothed. the older take one side where the frames disagree picks per pixel and per made frame,
      and on moving edges that turned into noise; this one is meant to replace it. 0.4 to 0.5 ms more a pair.
    - **keep the followed character whole**: a still or slow thing in front of moving scenery (the character the camera
      follows) keeps its outline, ground only one of the two frames shows is filled from around it, and the picture's
      border is left alone. about 0.3 ms more a pair.
    - **show a real frame across a cut** (output rate only, grey without one): when most of the picture fits no motion (a cut, a camera
      whip), the slots show the nearer real frame instead of a made one torn between two pictures, until most fits
      again.
    - **made frames as sharp as real ones**: a made frame is moved by fractions of a pixel and loses fine detail on the
      way, about 0.88 of a real frame's on the test clips. this gives it back (0.98), held inside what is around each
      pixel so nothing rings. a slightly wrong match gets sharper too. 0.16 ms more a made frame. with an output rate
      most frames on screen can be made ones, which is when it matters most.
- **generate at**: apple's interpolator is quicker on a smaller picture. this hands it a smaller copy of each
  real frame and scales the generated frame back up; real frames are not touched. full size takes about 11 ms a
  frame, 1536×864 about 7.4, 1344×768 about 6, and 1280×720 (its fast path, what "generate at 720p" was) about 3.6.
  generated frames get softer on the way down, seen most on fast pans: against the real 60 fps frames of two
  clips, 30.8 / 30.3 db at full size, 30.5 / 29.6 at 864, 29.9 / 29.1 at 768, 28.1 / 28.0 at 720. the in-between
  sizes are shrunk on the cpu (a plain area filter in six bands, about 0.6 ms). 1080p sources only, and it only
  saves delay on the early schedule, and there only with the deadline "by the usual" (below): by the slowest
  never waits less than 12 ms. measured, real frame arrival to its present call: 30.6 ms at full size, 26.5 at
  864, 24.9 at 768, 22.6 at 720 (28.8 at 720 by the slowest).
- **frame schedule**: on the tick gives the steadiest motion. early shows frames a few ms sooner (about 3).
- **generated frame deadline** (early schedule): how long after a real frame arrives its generated frame is
  waited for. **by the slowest** (as it always was): the slowest frame of the last few seconds plus 2.5 ms, and
  never under 12 ms. safe, but one slow frame holds every frame back, and the second generator on a shared gpu
  nearly always has one. **by the usual**: the time 95 in 100 of the last 120 frames were made in, plus 2 ms, no floor
  (still at most 15 ms). a quick generator then gets its frames up sooner, and about one in twenty comes too late
  and is left out (or shown a refresh on, next switch). with apple's interpolator at full size it changes next
  to nothing: its frames all take about the same.
- **show late generated frames a refresh later**: a generated frame that is not ready when it is due is shown
  when it comes, as long as a whole refresh of the screen still lies between then and its real frame. that needs
  a screen that refreshes faster than the source sends: 100 or 120 hz, or variable refresh in full screen. on a
  60 hz screen with a 60 hz source the next refresh is the real frame's, there is no room, and the frame is left
  out as before (the overlay shows the switch amber, idle).

### output rate

frame generation as above makes one frame between two real ones, and only when the source sends every frame twice.
the output rate (motion menu, experimental, off) plans the screen's frames on its own: each slot shows the game as it
was a fixed delay ago, a real frame where that lands on one, a made frame at that point between two real ones where
it does not, or the newest frame held when the next is not in yet. so a game that dips to 25, runs unlocked at 40 or
sits at 30 on a 100 hz screen still gets even motion. all of it was built and measured on replays and a handful of
runs on one 100 hz screen; read the numbers with that in mind.

it needs frame generation on (so macos 26), and a source the path takes (uncompressed 4:2:2, which every route meyra
has delivers). otherwise the menu items are grey and the overlay row says why. off is always there as the way back.

- **every signal tick**: a frame on every tick of the signal, 60 a second from a 60 hz signal, every gap between two
  real frames filled however long it is: dips under 30, unlocked rates. needs a screen at the signal's rate or variable
  refresh.
- **every screen refresh**: a frame on every refresh at the screen's own rate (100, 120, 144 hz); most of what you see
  is made. the display is left at its rate and match display refresh is grey. on a screen a little off the source
  (60.00 hz for 59.94) nearly every frame is made, at a point that rolls through the gap every 16 s, and the delay is
  about a refresh more. at 100 hz it leaves out a frame now and then (0.4 to 0.8 a second measured).
- **fixed 30 / 50 / 60 fps**: that many frames a second at even times, whatever the source sends: 25 or 40 fps filled to
  60. needs a screen at a multiple of it or variable refresh; fixed 60 on a 100 hz screen cannot be even (10 and 20 ms
  steps on the glass). 50 is untried on a screen.
- **times 2 / 3 / 4**: that many times the source's frames, evenly spaced in every gap. **times 2 following the gap**:
  twice the usual rate, and as many made in a longer gap as fit it, meant to keep the output steady when the game dips.
  frames never go up faster than the screen refreshes: a times mode the screen cannot take is thinned, down to real
  frames only (60 fps content on a 60 hz screen), and the overlay says "the screen takes n /s".
- **source rate (real frames only)**: nothing made, each real frame a fixed delay after it came, as even as the
  source sends them. not the source rate under match display refresh, which sets the screen's rate.
- **which generator fills what**: block matching makes a frame at any point. apple's interpolator and the second
  generator only make the middle; the other slots then show the nearer real frame, and the overlay says "apple's and
  the second generator make only the middle: pick block matching or blend".
- **blend in-betweens instead of generating**: the frames in between are a cross-fade of the two real frames by time.
  no motion to get wrong, softer, little gpu time. works whichever generator is chosen, but it is the block generator's
  code: if that cannot start, nothing is made and the motion line says why.
- **real frames** (fewest, some, more, all): only where the screen's rate is not a whole multiple of the game's (30 on
  100 hz, 25 on 60). a slot this close to a real frame shows the real frame rather than a made one a little off its
  time: fewest within 5 % of a gap (a step at most 1.6 ms off; 30 fps on 100 hz: 10 of the 30 real), some within 10 %
  (the default, 3 to 4 ms off, 20 of 30), more within 15 % (4 to 6 ms, all 30), all at the nearest slot (up to half a
  refresh off). more real frames: fewer made ones and their faults, a little less even motion. a whole multiple (30 on
  60 or 120) shows them all whatever this says.
- **ride out dropped frames** (off, one, two, three ticks): delay held on purpose. a tick is one frame of the signal,
  17 ms at 60 hz. without it a game frame that comes late holds the picture once, the delay rises, then falls back with
  a short speed-up. with it the late frame is still in time and the longer gap is filled with made frames at even
  steps: no hold, no rise, no catch-up. one tick covers a frame a tick late (a 50 ms gap at 30 fps) and capture jitter;
  two cover a missed frame (66 ms, the one before shown twice); three a game that misses two in a row (100 ms) holds one
  slot, not two. on replays of a 30 fps game dropping a frame a second, at fixed 60: one tick took the 50 ms case from
  60 holds a minute to none; the 66 ms case needed two (119 to none). the price is that delay all the time, and the
  overlay's delay says how much of it is held: "(33 held for drops)".
- **even out the game's late frames** (needs ride out; with every signal tick, every screen refresh or a fixed rate):
  most 30 fps games move their picture a fixed step a frame, late or not (measured on one: a 50 ms frame moved as far
  as a 33 ms one). shown by when it came, such a frame crawls at two thirds speed for three refreshes: a rattle on near
  detail while turning. with this, each frame is shown one step after the one before, the content plays a little slower
  while the game is late (eased over a third of a second) and the delay floats inside the ride out. on replays of three
  traces of that game the speed error fell from about 10 % to 3 to 4 %. what it costs, plainly:
  - more delay: about a tick and a half more at the same ride out. at two ticks and fixed 60 the picture sat 48 to 109
    ms behind arrival, mostly about 84.
  - nearly every frame on screen is a made one (about 58 of 60 a second, against 30 without), so made frames' faults
    show more, and they look softer: made frames as sharp as real ones is worth turning on with it. real frames is
    held to 2 % of a gap under this switch, whatever it says.
  - the sound is not stretched: it stays at the mean while the picture swings around it, up to about 30 ms either way
    for a moment. untested by ear.
  - wrong for a game that catches up after a late frame (moves by the time passed): that one gets the rattle instead.
  - a missed frame (66 ms and more) and a freeze go by arrival as before.
- **enhance the made frames too**: without it, the enhance net after the generator steps aside as soon as more than one
  frame in ten is made (with even out, nearly always), on real frames too, so the picture stays alike. with it the net
  runs on every frame that goes up, made or real. a 6x16 net at 1080p costs several ms each, and at 60 a second made and
  real that is a lot: checked once a second, when the gpu time of a frame passes nine tenths of a slot or more than 2 %
  of made frames come late for two seconds running, the net goes off on all frames for 15 s, then tries again, twice as
  long each time up to 4 minutes. with enhance real frames only, made frames get the net itself here, not the real
  frame's kept change. a net in the chain before frame generation needs none of this. not tried on a screen with a net.

what the output rate does to the rest:

- while made frames are more than one in ten of what goes up, the enhance net after generation, apple super resolution
  and stabilise step aside, until made frames are under one in twenty-five for 3 s. source rate and all-real cases keep
  them.
- the frame schedule, the generated frame deadline and late frames a refresh later decide nothing; their overlay rows
  say "by the output rate". the capture clock times the frames whatever its switch says ("used by the rate").
- the delay rises at once when a frame comes later than it covers and gives back slowly (5 % of real time). made content
  never steps back on the glass: a made frame that is late is left out.
- the still rule and hud lock take the nearer real frame of the pair. hud lock can flicker for a moment when the delay
  rises past two gaps.
- the sound follows the picture's delay as it is on the glass.
- glow with past picture (side bars) falls back to the glow.
- built-in presets turn the output rate off and put its switches back to their defaults.

the overlay shows an `out` line while it runs: frames a second and how many were real, made, nearer real (a slot whose
in-between was never asked for), late and held, then left out, the late-evened speed and the screen's rate. the
method follows macframegen and metalgoose, see `THIRD_PARTY_NOTICES.md`.

### huds and still things

the guess is at its worst where nothing should move: a minimap, a health bar, a wall behind a moving
character. three ways to keep those on the real frame, from automatic to "you say where".

- **still areas in generated frames**: a generated frame is a guess, and the guess makes things that do not
  move (a hud, a wall behind a moving character) shimmer. so pixels that did not change between the two real
  frames are taken from the real frames instead. the rules differ in what counts as "did not change":
  - **exact match only**: the two real pixels have to be the same. safe, but game pictures are rarely that
    still, so it does little.
  - **soft**: allows the small differences dither makes. steadier huds and backgrounds, thin moving things
    mostly survive.
  - **by motion against contrast**: compares how much a pixel changed with how much contrast is around it.
    steadiest backgrounds, can fade a thin line moving over a busy area. this and the next are ported from
    metalgoose, see `THIRD_PARTY_NOTICES.md`.
  - **by motion against contrast, allows for dither**: the same, more forgiving. steadiest of all, and can
    erase thin moving things.
- **hud lock** (experimental): the still-area rule looks at one pair of real frames. this one remembers: per
  pixel, how long it has been still and how much edge it has. after about 1.3 s of standing still, edge pixels
  (text, icons, outlines, and the pixels right next to them) are taken from the real frame in every generated
  frame. a pixel that moves lets go at once. works on top of whichever still-area rule is chosen. costs one
  pass over the picture per real frame (nine texture reads a pixel) and up to ten state reads more per pixel of a generated frame. ported
  from pushfps (see `THIRD_PARTY_NOTICES.md`). hidden: `hudStill` (levels of 255, default 5.1), the largest
  change that still counts as still.
- **hud areas**: a minimap, a health bar or subtitles shimmer in generated frames when the picture moves behind
  or inside them, and no rule can know what is hud. so you say it: Q (or motion > mark hud area), then drag a
  rectangle on the picture. inside it every generated frame takes the newer real frame's pixels, with three
  pixels of soft edge. up to 8, kept in the setting `hudRects` as parts of the picture
  (`x,y,w,h;x,y,w,h`, from the top left), so they fit any window size and full screen. clear hud areas forgets
  them all, show hud areas outlines them while the status overlay is on (they are also outlined while marking and for a moment after). works
  with every still-area rule, hud lock, both generators and generate at 720p; the overlay says how many are
  set. what it costs: whatever moves inside a rectangle moves at the game's own 30 there, half a step ahead of
  the picture around it, so mark tight. measured on a 60 fps clip with a burned-in overlay: see the numbers in
  the changelog. they are per source, not per game: clear them when you change game.

### cuts, repeats and timing

four experimental switches about telling frames apart and when to show them. all off unless you or a preset
turn them on.

- **cut test** (experimental): no frame is generated across a scene cut. without the switch a cut is "the mean
  difference of the two frames is over 40 of 255", which misses cuts between similar shots and stops on
  flashes. with it, the two frames are compared as 64x36 coarse pictures plus a histogram: a cut is cells and
  histogram both apart, or cells apart and nothing lining up. a brightness jump with the same picture
  underneath is a flash and gets its frame, and so does the frame after a jump that is back where the picture
  was before. pairs that are neither still go by the old limit, so very fast motion is skipped as before.
- **tolerant repeats** (experimental): meyra tells a 30 fps game in a 60 hz signal by its repeated frames, and
  a repeat has to match bit for bit (bar 10 of 2048 samples). some usb capture cards hand repeats back with
  a fifth of the pixels one level off: every frame then looks new and frame generation stops. with the switch a
  repeat may be up to 3 levels off per sample (130 thousand samples, against the last new frame), as long as no
  more than half a percent of them are further off and no more than two of 510 blocks have shifted their mean
  by a quarter level. the second test is what keeps a slow pan or a fade from being called a repeat.
- **capture clock** (experimental): on the early schedule, presents are planned from the moment a frame
  arrived. a capture card whose callbacks wobble by a few ms makes every present wobble with them. with the
  switch the plan starts from the frame's capture timestamp plus a tracked offset between that clock and the
  mac's: one late callback is ignored, two in a row on the same side are followed. the plan sits later than the
  mean arrival by twice the mean wobble (8 ms at most), next to nothing on a clean source. changes nothing on
  the tick schedule or without frame generation: frames go up as they arrive there.
- **skip only after a lasting backlog** (experimental, off): while no frames are generated (frame generation off or
  idle, plain passthrough) an exact repeat is left out to catch up as soon as the screen's queue runs two frames
  behind. with the switch only once it has been behind for half a second without a break, so not after
  one slow frame, a backlog that lasts is cleared as before.

### the screen and the last few ms

what meyra does with the display, and what it asks of macos and the gpu.

- **match display refresh** only touches the display when its rate is not a multiple of the source's (a 100 hz
  display with 60 fps content), and only while meyra runs.
- **variable refresh**: if the screen has adaptive sync (set its refresh rate to "variable" in system settings)
  or promotion, go full screen. meyra then leaves the mode alone and the screen shows each frame as it comes:
  even motion and much less delay than a fixed 60 hz mode (measured on a 48-100 hz screen: about 5 ms without
  frame generation, 36 ms with, against 25 and 85). in a window macos draws at the screen's top rate, so there
  the matched mode is used as before.
- **vsync**: off shows frames without waiting for the display, a few ms sooner, and can tear. on a variable
  refresh screen it makes next to no difference (measured 1 to 2 ms).
- **take the screen buffer late** (meyra menu, experimental, off): the screen's buffer is asked for after the
  frame's gpu work is written down, not before, so a buffer that is still on screen no longer holds that work up.
  it costs gpu time: on a replay at 1440p on an m4 max the gpu's time a second went from about 110 to about 200 ms
  with it on. whether it buys delay is not measured yet.
- **two screen buffers instead of three** (meyra menu, experimental, off): the layer cycles two buffers, not three:
  one frame less can queue before the screen. can stall when a frame takes long.
- **game mode**: meyra tells macos it is a game, so full screen gets game mode (more cpu and gpu priority,
  quicker bluetooth controllers and headphones). off is macos' own per-app switch, the same one as in the game mode
  item in the menu bar: a per-user flag outside the app, the app itself is not changed. it may count only from the next
  start. where macos has no such switch (it is not public, so older versions may lack it) the item is grey and says so.
  v0.5.0 turned it off by editing the app's `Info.plist`, which broke the signature, and macos then refused the camera
  without asking: see [when something is off](#when-something-is-off).
- **keep the gpu awake** (meyra menu, off): the gpu slows its clock when it has little to do, and one net run or
  one generated frame every 16 ms is little: the same work then takes about twice as long as it would back to
  back. macos has no way to ask for the clock, so this keeps a small job on the gpu (32 threads spinning for
  1.5 ms out of every 2, on a queue of its own). measured in alternating runs on a shared machine: second
  generator 6.6 -> 4.1 ms a frame (95th percentile 10.5 -> 6.8), a 6x16 enhance net 7.3 -> 4.4 ms, both
  together 8.9 -> 5.7 ms for the generator. it costs power and heat for as long as it runs (not measured: that
  needs root), apple calls the trick wasteful and an os update can stop it working. so it only runs while meyra
  is the app in front, a picture is coming in, and an enhance net or the second generator is on. when something
  else already has the gpu full it makes things worse (with a training job at 97%: 130 -> 78 of 294 generated
  frames in time): then leave it off.

### sound

- **play audio**: the source's sound, held back so it lands with the picture. off if the console's sound
  goes somewhere else.
- **earlier / later**: nudges the sound 5 ms at a time, for when lips and voices are off.
- **where it comes from**: source > audio input, not the audio menu. the overlay's audio row says "in step with the
  picture" only while sound comes in; in brackets the input it comes from and how it was found, then the output it
  plays on. without an input it says "no audio input" and where to pick one.
- with an output rate the sound follows the picture's delay as it lands on the glass, ride out included. with even out
  the game's late frames it stays at the mean while the picture swings around it.

### window, overlay and comparing

- **status overlay**: source, frame rate, delay, and most switches with their key and what they are set to. the
  `order` line at the top is what the frames of the last second really went through, in the order it happened;
  a step that is switched on and did not run is named with the reason (`metalfx idle: window not larger than
  source`). `cadence` is new frames in the signal's frames, `30 in 60` for a 30 fps game. when frame generation
  is on and makes nothing, the motion line says why.
  H steps from off to compact to full. compact: the steps left to right as they ran, each with a dot (green it ran,
  amber it is on but idle) and its key, one line of numbers and the presets. full: the switches in three columns,
  picture, motion, and now (source, timing, gpu ms per stage, window and presets). the row changed last is lit.
  with an output rate the numbers line gets the delay held for drops and an `out` line (see
  [output rate](#output-rate)); a card that sends too few frames gets an amber line of its own (see
  [too few frames from the card](#too-few-frames-from-the-card)). the full overlay has rows for the side bars, the
  letterbox crop, the side stretch, the six newer block matching switches and every output rate switch, each with its
  reason when it is on and idle ("needs ride out drops", "the source's picture format is not one it takes", "canvas,
  glow only"); a long reason goes on over the next rows. not in it, menu only: match display refresh, super
  resolution's pad edges and run with frame generation, where enhance runs and its smaller windows, side bar
  softness and game mode.
- **hints**: after a key or a menu command one line says what is set now and what that does. it stays until the
  next key while the overlay is up, 6 seconds otherwise. the menu items carry the same texts as tooltips.
- **compare** (/, shift + / goes back): the original against the finished picture, with a caption on each. the original
  is what the source sent, and while a generated frame is up it still shows the real frame before it, so its half moves
  at the game's own rate. five ways: cut **left / right**, **above / below** or **diagonal** (left and below the line is the
  original), and **side by side** or **stacked**, which show the same middle half of the picture twice. then every stage of
  the chain (as it came, dither removal, enhance, upscaler, look, the result) as strips, each its own part or the same part
  of the picture, named at the bottom. it draws over the finished frame, so snapshots never have it.
- **freeze** (space): the newest real frame stays up, and every switch but the noise filter (as it was then) still acts on it: for comparing strips, nets
  or the look without the game moving. generated frames are not frozen, only real ones. sound and source run on, a
  new source lets go of it. not saved.
- **window size**: steps through 720p, 900p, 1080p, 1440p, 2160p and the largest that fits.
- **full screen keeps the window's resolution**: renders at the window's size and scales that to the screen,
  instead of rendering at the screen's size. lighter on the gpu. the picture keeps its ratio, also on an
  ultrawide. in full screen W steps through the size it renders at (720, 900, 1080, 1440, 2160 lines, those under the screen's, then the screen's own).
- **streaming**: the window is titled "Meyra". keep it visible while another app captures it, macos stops
  updating covered or minimised windows.

### side bars

a 16:9 game on a wider window or screen leaves bars beside the picture, or above and below it on a taller one. picture
> side bars (experimental, all off) decides what goes there. the picture's own pixels are never touched, snapshots and
recordings leave the bars out, plain passthrough turns them off, and none of it is in presets. the looks were checked on
pictures from a test tool, with little play on a screen yet.

- **grey**: one flat dark grey instead of black, easier on the eyes next to a bright picture. next to no gpu. with the
  brightness steps: very dark, dark (default), medium, light (10, 19, 29, 38 of 255).
- **glow**: each bar glows in the colours of the picture's edge next to it, softer and darker further out, carried
  straight out (not mirrored, else a pan would run the other way in the bar), with a dither of one level so dark
  gradients do not band. it follows the picture a little late (200 ms; `sidesmooth:MS` or the `sideSmooth` setting, 30 to
  1000) so a flash does not strobe there: flashes up to 125 ms barely reach the bars, a longer one comes in and goes
  out a step each. a cut reaches them about an eighth of a second later. brightness steps as for grey, kept well below
  the picture by default so a screen that dims on bright frames does not darken the game; softness: less soft, soft
  (default), very soft. the frame's own gpu work is the bars alone (about 0.02 to 0.04 ms); the rest runs after the
  frame has gone to the screen.
- **glow with past picture** (an experiment on top of the glow): what the picture showed beside its edge a moment ago is
  carried out into the bar as the picture moves, so a pan fills the bar on the side the picture moves away from, darker
  and fading into the glow over about 1.5 s. where it is unsure (the side the camera turns towards, cuts, zoom or forward
  motion, flat areas, things at different depths) it is the glow; marked hud areas and parts that do not move with the
  picture are kept out. on gameplay footage it mostly shows the glow with a faint copy in the first ~70 px. not with
  the side stretch, not with an output rate, not while the letterbox crop fills the window: the glow then, and the
  overlay says "canvas, glow only". costs about 0.4 ms of cpu a new frame (about twice that from a 4k source), after
  the frame has gone to the screen.
- **fill the window with letterboxed pictures**: a game showing a wide picture with black bands above and below (a
  2.39:1 cutscene) gets the band made larger until it fills the window. it takes bands of 4 % of the height or more each,
  the picture between them 1.9 to 2.8 wide, its edges lit, steady for a second; a dark scene or a fade never counts. it
  lets go in the same frame anything shows in the bands (subtitles in the band too). a game that boxes only some shots
  gets a longer hold each time inside 10 s (1, 3, 6, 8 s), so it does not pump. eased in over 200 ms, out at once. a
  little softer than without: the finished picture is scaled once more (about 85 to 90 % of the fine detail of making it
  at that size). not with a compare view. snapshots stay the whole picture; recording while it fills the window keeps
  only the middle, the outer parts of the wide picture are not in the file. hud areas cannot be marked while it fills
  the window.
- **stretch a third, two thirds, to fill**: the picture grows into that much of the side bars. the middle stays at its
  true shape (0.3 of each half, about the middle fifth of a 3440 wide screen at full), past it each column gets wider
  towards the edge, smoothly: faces in the middle keep their shape, huds and minimaps at the edges get wider, and things
  speed up as a turn carries them out. at full on a 3440x1440 screen from 16:9 the very edge is about 2.5 times as wide
  as the middle. grey or glow fill what it leaves. the letterbox crop wins while it fills the window. not with a compare
  view. snapshots stay unstretched; recording while stretched keeps only the middle of the screen, bent, not the outer
  parts of the picture. hud areas cannot be marked while stretched. hidden: `stretchCentre` (0 to 0.6, 0.3), the middle
  that stays true, 0 for the plain curve.

### recording

- **recording** (tab): what is on screen, generated frames, compare view and all, goes to a .mov in movies/meyra: hevc from
  the mac's video encoder, with the sound as it is played. at most 1080p high unless the recording menu says otherwise
  (as shown, 2160p, 1440p, 720p): a bigger picture is scaled down on the gpu first. bitrate by size (37 mbit at 1080p,
  66 at 1440p) or one picked in the menu. the file carries the tone curve the colour setting shows the window with. a red
  dot sits in the corner meanwhile, which is never in the file, and neither are the overlay and the hint lines unless
  the recording menu says so. the screen never waits for it: each frame is copied on the gpu and handed on, and when
  the encoder or the disk fall behind the file loses a frame, the screen does not. measured on an m4 max, windowed
  and full screen, standard and the heaviest preset: generated frames, late frames and generation time the same with
  it as without, within what runs differ by anyway. starting and stopping hitches for a few frames. a change of the
  picture's size (window size, full screen), of the size, bitrate or colour setting ends the file and goes on in a new one. it stops itself under 2 gb of
  free disk, and a quit closes the file.
- **keep the last 30 seconds** (shift + tab): the same, but encoded into memory all the time (about 140 mb at 1080p)
  and written only when tab is pressed: for what just happened. an amber dot in the corner shows it is on, it turns
  white for a moment at a save. the choice is remembered. `-recKeepSeconds N` for another length, `-recMbit N` for
  another bitrate, `-recDir PATH` for another folder.

## the gta6 weights and the others

the nets whose name starts with **GTA6** are our own, trained on footage of gta vi and nothing else. on other games
they may well do worse, and nothing was tested there. most work at the source's size (the `own` ones
without `1x` make 2x), on luma, one frame at a time. sizes are layers x features: 4x8 is the light one, 12x32 the heavy one. presets 8, 9 and 0
use "teach general 6x16".

| family | trained to | what it does |
|---|---|---|
| `teach general`, `teach x2plus` | copy what realesrgan (general-x4v3 or x2plus) makes of a frame | removes grain, cleans jagged edges. general 6x16 reproduces 67% of the big net's change, 12x32 75%. the x2plus ones are milder (39%, 47%). `edges` only touches strong edges |
| `detail` | rebuild 4k console footage from a lower copy of it (`pix` pixel loss, `perc` with vgg features, `gan` with a small gan term) | +2 to +3 db on made-up test pairs, on real frames a grain remover and edge cleaner: no detail that was not there. steadier picture |
| `look` | copy before / after videos with the dlss 5 look, `detail` for its local part only | takes in little of it, the curve switch (look, key .) does more |
| `own applelike` | copy apple's 2x super resolution scaler (`1x`: its picture brought back to the source's size) | first tries, from 92 captured frames: a feasibility test, not tuned |
| `own rebuild` | rebuild the picture from its own half size copy | the same |
| `own 1x restore` | undo a little blur and the game's dither, `raw` before dither removal | the same |

what they were trained on: our own series s captures, and public videos of gta vi (ps5 pro footage and dlss 5
comparisons). no frame of those videos is in meyra. the numbers are held-out frames of the same shots, not of other ones.

not ours, general, and under their own licences (see `THIRD_PARTY_NOTICES.md`): fsrcnnx, artcnn, and
`realesr-general-x4v3`, unchanged weights of real-esrgan. that last one is far too slow to run live (a still
picture, picked from the menu, the n key passes it by). the second frame generator's weights are not included, they
are noncommercial.

### add your own weights

1. put your `name.net` file into `~/Library/Application Support/Meyra/nets/` (make the folder if it is not there).
2. restart meyra.
3. press N, or pick it under picture > enhance.

a file is plain text: the layers of a small net and their numbers. the format is in `resources/nets/README.md`, and
the files in that folder are examples. `python3 tools/mpv2net.py shader.glsl "name" out.net` makes one from an mpv shader. the `name` line is what the
menu shows; if it was trained on one game, put the game first, like GTA6. a file that cannot be read stays in the
list and says why in the log.

## updates

meyra checks this project's github releases once at each launch and only speaks up when there is something
newer. turn that off in the meyra menu, "check for updates at launch".

- **what is sent**: one request to `api.github.com` with the app's name and version. no identifiers.
- **installing**: the download must match the sha-256 in the release notes, then it is checked to be meyra,
  newer than what is running, and correctly signed. only then is the app swapped and restarted. if anything
  fails, the app stays as it was. no checksum in the notes, no install.
- **reverting**: the replaced version is kept in `~/Library/Application Support/Meyra/Previous Version/`.
- **limits**: the checksum guards against a broken download, not against a compromised account. builds are
  signed ad hoc for now, so macos asks for camera and microphone access again after an update, or refuses capture
  while the switch in system settings still looks on (see [when something is off](#when-something-is-off)). meyra cannot
  update itself from a disk image or straight out of downloads, move it to applications first.

## when something is off

moved to one place: [help](README.md#help) in the readme, symptom by symptom, each with the menu item or key that
fixes it. also in the app under help > common problems and fixes. what cannot be fixed is under
[known limits](#known-limits); questions go to the [discord](https://discord.gg/UpgbaZEUj4), with a
[debug report](#debug-report).

## debug report

help > copy debug report puts a plain text on the clipboard, to paste into an issue: what is needed to see what runs,
without asking ten questions first.

- **machine**: meyra's version and build, macos, the mac's model, chip, memory, cores, gpu, thermal state, low power mode.
- **displays**: each screen's size in points and pixels, scale, refresh, its top rate and variable refresh range, which
  one is built in, main, and has the window.
- **source**: name, kind, format and layout, whether compressed is offered, audio input as automatic, none or chosen
  with the input's name, how automatic found it and what it runs (`audio input auto -> USB3 Digital Audio (same usb
  vendor:product), 48000 Hz 2 ch, open`), or why there is none, its state, the too-few-frames line.
- **now**: the order line, frames in, new, cadence, delay, gpu, why frame generation makes nothing if it does not, gpu
  ms per stage, window size, overlay, preset, the sound line, the message on screen or the last one and how long it
  has been gone, the last error, the capture line (frames from the device,
  timestamp spacing, drops by reason, what macos runs) and the same counts since the source started.
- **capture start (kept)**: kept apart from the log so they are still there after minutes of play: each source start
  with its format and layout, what was asked and what macos ran after the start and a second later, whether meyra had
  to set it again, the first frame's size and layout, the audio input and how it was found or why there is none, the
  first too-few-frames line and test switches in use.
- **access**: camera and microphone permission as macos has it (read only, never asks; from terminal they are the
  terminal's), whether the app's signature holds, and whether it is signed ad hoc.
- **devices**: what `--list-devices` prints: per device what audio input > automatic takes and how, or why none; per
  audio input how it is connected (usb, built-in, virtual, continuity, bluetooth) and its usb vendor:product.
- **changed settings**: every saved setting that differs from what meyra uses when it is not set, and test switches
  given on the command line. per-source entries carry the short hash, so two sources can be told apart.
- **log, last lines**: the last 20 of the once-a-second lines and the source lines; the others carry device ids and
  folders, so they stay out.

what is taken out: your home folder (as ~), the mac's name, your full name, an owner's name in front of or behind a device
("someone's iphone camera" becomes "iphone camera", "iphone von …", "iphone de …", "iphone d’…", "iphone di …",
"ipad van …", "アレックスのiphone" become "iphone", "ipad": a name with an apple device in it, a plain mac too, keeps only the
device, camera and microphone words, in any case or script; other names lose an owner behind von, de, di, van, d’ and
the like, or in front of 's, 的, の, 의, and keep the rest, so a card or screen stays recognisable; every line of the
report gets the same for the device names in it, the last message too), usb serials, mac addresses and other long
ids (usb ids become vendor:product), audio input ids, and folders in values (only the last part stays). not caught: a
name in front of another make's device with nothing between ("alex bose"), a device named only after its owner ("alex
camera"). read it before you paste it anyway.

`Meyra.app/Contents/MacOS/Meyra --debug-report` prints the same and quits, with no window, so without the source, now,
capture start and log sections.

## known limits

- bluetooth headphones have more delay than the picture, their sound cannot be brought in step.
- frame generation can smear backgrounds on very fast pans.
- some consoles at 1440p are reported by the ultrastudio recorder 3g as 1080i and give no picture. set the
  console to 1080p.
- surround sound is folded down to stereo. dolby and dts bitstreams are not decoded, set the console to pcm.
- a usb webcam without camera or webcam in its name ("logitech brio") is taken for a card: on automatic it can get its
  own microphone, by the same name as before 0.6.2, and since 0.6.2 also when the microphone shares its usb maker and
  model or carries its name in its id. the overlay's audio row names the input; if it echoes, choose none in source >
  audio input.
- an audio input picked by hand is kept per source id, and macos likely gives a usb card a new id on another port: moved,
  it starts on automatic again (which finds a card's own sound by itself since 0.6.2). pick it again if needed.
- interlaced formats are shown without deinterlacing.
- capture cards that deliver compressed video may defeat repeated-frame detection, which frame generation needs. the
  compressed layout has not been tried on a card that offers it.
- the output rate needs macos 26 even for source rate and blend, and takes uncompressed 4:2:2 frames only (what every
  route meyra has delivers). 24 / 25 fps content and the 50 fps rate are untried on a screen.
- ride out dropped frames on 60 fps content: a picture that comes a few ms late on an otherwise usual gap is in time,
  but the delay then rises a whole refresh on the next picture for a fraction of a second and comes back with a short
  speed-up (on a replay of the recorder's timing, 59.94 on fixed 59.94 at one tick: 25 to 42 ms for 0.15 to 0.8 s, 9
  times in 10 minutes). 30 fps games, what the switch is for, do not show it. a fix that netted the late picture took
  more holds on a mixed 30 / 40 / 60 replay, so it is not in.
- the output rate as a whole is experimental. seen in a log of a real run:
  - every screen refresh on a clean 60 fps source, ride out off: the planner still holds a slot now and then (about 10 a
    minute) and the delay saws between about 16 and 45 ms. short slow-downs in presenting can add a few missed refreshes.
  - times 2 on 60 fps content on a 100 hz screen makes no frames and still adds a frame (about 16 ms) of delay. with
    variable refresh the overlay's uneven gaps count is wrong in that mode (it measures against the rate, the screen
    shows 60).
  - while a rate runs, the overlay's top line can say "frame generation idle: waiting for a pair of frames" or "the
    picture is still" though the rate is working.
  - leaving or entering full screen with a rate running costs a visible hitch, about half a second.
  - very uneven sources (4 to 20 new frames a second) swing the delay by tens of ms with ride out off.
- capture clock drift on 30 fps content: the output rate follows a card clock that drifts against the screen on its
  own slots, but not while a gap between two real frames is handed out, which is most of the time with a 30 fps game.
  over many minutes at a fixed 60 the delay could walk up by a tick. not measured, open.
- not new, there since v0.5.0: on a still picture with frame generation on, the sound can jump about 0.2 s late for a
  couple of seconds after a long-held frame.
- recording while the letterbox crop or the side stretch fills the window keeps only the middle of the screen. side bars
  are never in snapshots or recordings.

## building

```sh
make            # builds build/Meyra.app
make run        # builds and opens it
make clean      # removes build/
make DECKLINK=0 # builds without the blackmagic driver
```

the build signs the app ad hoc, good enough to run on the mac that built it. `VERSION` in the `Makefile` is the
only place the version lives. `OUT`, `BUNDLE_ID` and `SIGN` can be overridden, e.g.
`make SIGN="Developer ID Application: NAME (TEAMID)"`.

## development

| path | contents |
|---|---|
| `src/app.mm` | application, window, menus, source picker, overlay, command line |
| `src/common.mm` | settings, log, clock |
| `src/renderer.mm` | metal pipeline, frame analysis, presentation schedules, the output rate's path, render thread |
| `src/slots.h` | the output rate's planner: which picture goes up on which slot, the delay, ride out, even out. plain c++, no app in it |
| `src/sidefill.mm` | side bars: grey, glow, the stretch's last pass, the letterbox crop's zoom |
| `src/canvas.mm` | side bars: glow with past picture |
| `src/letterbox.mm` | finding the black bands of a letterboxed picture |
| `src/debugreport.mm` | the debug report's machine, displays and settings parts, and what it takes out |
| `src/cadence.h` | comparing frames and timing them: tolerant repeats, scene cuts, the capture clock |
| `src/hashstab.mm` | shaders of hashed filters and stabilise, built the first time one of them is used |
| `src/framegen.mm` | frame generation thread |
| `src/flyhigh.mm` | second frame generator |
| `src/blocks.mm` | block matching frame generator |
| `src/nets.mm` | enhance nets: files in, metal shaders out |
| `src/noise.mm` | noise filter |
| `src/awake.mm` | keeps the gpu's clock up |
| `src/superres.mm` | apple super resolution thread |
| `src/audio.mm` | audio ring buffer, delay matching, output |
| `src/record.mm` | recording: what is on screen to the hardware hevc encoder, a .mov in movies/meyra |
| `src/source*.mm` | capture: system route, vendor drivers, replay |
| `src/display.mm` | display refresh matching |
| `src/update.mm` | updates from github releases |
| `resources/Shaders.metal` | shaders, compiled when the app starts |
| `vendor/decklink/` | blackmagic desktop video sdk headers |

> [!TIP]
> **testing without a device.** source > open replay folder, or `--source replay:PATH`, loops raw frames named
> `NAME_f000.uyvy`, `NAME_f001.uyvy`, … (one 1920×1080 frame of 8-bit 4:2:2 uyvy each, no header) at 59.94 fps.

<details>
<summary>command line arguments</summary>

**command line**, e.g. `build/Meyra.app/Contents/MacOS/Meyra --source replay:frames/b1 --seconds 10 --log run.log`:

| argument | effect |
|---|---|
| `--list-devices` | print the devices meyra can see and exit. under each system capture device, every pixel layout it reports per size and rate (`*` what the format opens, `+` offered as compressed), the rate ranges, and the sizes the menus leave out with the reason. names are cleaned as in the debug report, ids shortened to a short id and a hash (`[avf usb 534d:2130 #1a2b]`) |
| `--list-devices --ids` | the same with the raw ids, as `--source avf:UNIQUEID` needs them |
| `--debug-report` | print the [debug report](#debug-report) and exit, no window |
| `--source ID` | `replay:PATH`, `avf:UNIQUEID` or `decklink:ID`, for this run only |
| `--seconds N` | quit after n seconds, never asks for permissions |
| `--log FILE` | write the once-a-second statistics to a file |
| `--snapshot FILE` | save one processed frame as png |
| `--capture-test FILE` | capture the window as other apps would, save as png |
| `--window WxH`, `--screen NAME`, `--fullscreen` | where and how to open |
| `--command NAME[@SECONDS]` | run a menu command after launch or that many seconds in, e.g. `sharp:0.3`, `upscale+@5`, `rate:3:60` (`rate:MODE:NUM`: fixed 10 to 240 fps, times 2 to 8) |
| `--menu-dump` | log every menu item with its state, and its tooltip on a `tip` line |
| `--set KEY=VALUE` | store a setting as if chosen in the menu |
| `-KEY VALUE` | override a setting for this run, e.g. `-frameGen NO` |
| `--update-check [URL]` | run one update check and print the result |
| `--update-test JSON ZIP APP KEPTDIR` | run the install path on local files, against a copy of the app |
| `--update-revert-test APP KEPTDIR` | put a copy of the app back from the kept bundle (test) |
| `--snapshot-at S`, `--capture-at S` | when `--snapshot` and `--capture-test` happen, in seconds (test) |
| `--gamemode-test [on\|off\|-] [KEPT]` | the game mode launch step and switch on this bundle, prints and exits (test: it changes macos' per-app game mode flag) |
| `--self-test` | checks that the I and M keys reach every choice and that the debug report's name rules hold, prints and exits |

</details>

<details>
<summary>setting keys, for <code>--set KEY=VALUE</code> and <code>-KEY VALUE</code></summary>

setting keys: `levels`, `deband`, `upscale`, `sharpen`, `frameGen`, `early`, `passthrough`, `audio`,
`audioTrimMs`, `refresh`, `overlay`, `overlayFull`, `checkUpdatesAtLaunch`, `srWithGen`, `srPad`, `vsync`, `colour`, `keepRes`, `gameModeOff` (since v0.6.0; v0.5.0's `gameMode` is read once and removed), `enhance`, `enhanceAt`, `enhanceDown`, `enhanceReal`, `enhanceHold`, `superSample`, `look` (0 to 3), `compare` (0 to 7), `netHalf`, `genSmall` (0 off, 1 1280×720, 2 1344×768, 3 1536×864; a saved yes still means 1), `genDeadline` (0, 1), `genLateNext`, `gpuAwake`, `genStill`, `genModel`, `denoise`, `hudLock`, `cutTest`, `repeatTol`, `ptsTime`, `hudStill`, `hudRects`, `hudShow`, and the experimental `genShift`, `genDoubt`, `repeatRoll`, `grain` (0 to 1), `stabilise`, `lateDrawable`, `drawables` (2 or 3), and for recording `recMaxHeight` (the file at most this high, 0 as
shown, 1080), `recMbit` (bitrate in mbit, 0 by size), `recOverlay` (overlay and hint lines in the file), `recKeep`
(keep the last 30 seconds). new in v0.6.0, all experimental: for block matching `genSmallFast`, `genFallback`,
`genSides`, `genOutline`, `genCutGuard`, `genSharp`; for the output rate `rate` (0 off, 1 every signal tick, 2 every
screen refresh, 3 fixed, 4 times, 5 times following the gap, 6 source rate), `rateNum` (the fps for 3, 10 to 240, 60
when unset; the times for 4 and 5, 2 to 8, 2 when unset), `rateBlend`, `rateSnap` (real frames, 0 to 0.45, 0.1),
`rateCushion` (ride out, 0 to 3 ticks), `rateEvenLate`, `rateEnhanceMade`, and `rateEven` (no menu: 24 or 25 fps in a
60 hz signal timed by an even clock, untried on a screen); for the side bars `sideFill` (0 black, 1 grey, 2 glow, 3 glow
with past picture), `sideDim` (0.3 to 0.95, 0.7), `sideBlur` (0.25 to 2, 1), `sideSmooth` (ms, 30 to 1000, 200),
`letterboxCrop`, `sideStretch` (0 to 3), `stretchCentre` (0 to 0.6, 0.3); and per source `layouts` (like `formats`).
`defaults delete io.github.k33bs.meyra` resets them.

</details>

<details>
<summary>hidden switches, for tests</summary>

hidden, for tests, on the command line only (a `--set` or `defaults write` of them is ignored): `-muteOutput YES`
(mutes the output, the sound path still runs and is measured), `-frameLog FILE` (one row per drawn frame, kept in
memory and written as csv at quit; also turns on the block generator's pair figures).

more hidden switches, for tests: `-netHalfMax N` (half precision up to layers of N features, 24), `-genSpinWait YES` (the
second generator's thread watches its command buffer instead of sleeping on it; measured no quicker, off),
`-enhanceAhead 2` (with the second generator, enhance real frames only runs the net once the generated frame is
made instead of next to it; 1 as it is, 0 not ahead at all), `-gpuAwakeBack YES` (keep the gpu awake also behind
other apps), `-drain NO` (plain passthrough never leaves a repeat out, as it used to), `-genDrain YES`
(frame generation leaves one generated frame out when the display's queue has been behind for half a second;
tried, did not bring the delay down, off), `--command huddrag:x0,y0,x1,y1` after `hudmark` (a drag in parts of
the view, through the view's own mouse handling), `-genFloor N` (early schedule: the least time a generated frame is
waited for, in ms, 4 to 15, 12; lower is sooner with a quick generator, more late frames), `-noise N` (the noise
filter's strength, 0 to 1, 0.5), `-chain PRE:POST` (which stages run before the interpolator on real frames and which
after, on every frame; none set is `:DUS`, the usual order. the letters are in `src/common.h`).

a few more sit with the switch they belong to: `-genModelDir DIR` (frame generator), `hudStill` (hud lock),
`-recKeepSeconds N`, `-recMbit N` and `-recDir PATH` (recording), `stretchCentre` (side stretch).

for the output rate, on the command line only: `-rateCap NO` (presents no longer held to the screen's refresh, for
testing the backed-up queue), `-rateDrain NO` (a backed-up queue is not shed), `-rateClock NO` (frames timed by
arrival on the path instead of the capture clock), `-rateTestLate N` (every nth made frame counts as late),
`-rateTestMax K` (a request holds at most k positions). on the command line or with `defaults write`: `rateFastWin N`
(how many gaps the quick fall of the delay looks at, 8), and for the replay source `replayJitter MS` (every frame
handed over up to that many ms off its tick, either way), `replayJitterSeed N` (12345), `replayJitterShape YES` (off
the tick the way a real capture measured). all of these are logged as `settings: KEY VALUE (test)` when set.
`autoCompressed YES`: a source that sends too few frames is switched to its compressed layout by itself, once per
source and run, only while no layout was ever chosen for it; off, because it restarts capture and adds delay without
asking.

for system capture, as launch arguments or with `defaults write` (none set: the usual start plus the read-back; they
show under changed settings and on a "test switches" line in the report): `-avfEarly YES` (format and rate set right
after the input is added, before the output), `-avfKeepLock YES` (the device stays locked from the format set until
after the start, as ffmpeg does; apple documents lock, set, unlock), `-avfReapply always` (format and rate set again
after the start even when they match) or `-avfReapply NO` (only look), `-avfOut 420v|420f|native` (what the output
asks for; 420v also prefers the device's own 420v format at that size and rate; native only where it is 2vuy, 420v or
420f, else 2vuy and the log says so), `-avfAll YES` (early, keep lock, reapply always and 420v together). with 420v or
420f the picture runs, but frame generation, the output rate and the noise filter take 2vuy only and stay idle.
compiled, not yet run on a card.

</details>

gpu milliseconds per step are in the overlay and on a `stages` line in the log (`-stageTimes NO` turns that off): convert, dither, enhance, upscale, shrink, sharpen, overlay, stabilise, against the frame time. it
reads gpu timestamps at the start and end of every pass. the net and metalfx are not passes of meyra's own, their
time is what lies between two that are, so a net at the source's size followed by metalfx shows as one figure,
`net+scale`. the numbers are time on the gpu's clock, other apps' gpu work that got in between included.

**making a release.** set `VERSION` in the `Makefile`, update `CHANGELOG.md`, run `make release`. it builds
`build/Meyra-vVERSION.zip` and `build/release-notes.md` with the checksum in it, and uploads nothing. on github,
create a release tagged `vVERSION`, paste the notes (the updater reads the checksum from them) and attach the
zip.

### adding a driver for another maker

got an elgato or something else with its own sdk? drivers are welcome. the blackmagic one in
`src/source_decklink.mm` is the one to copy:

1. write `src/source_<name>.mm` with a `Source` subclass (see `src/source.h`): `start`, `stop`, frames to
   `renderer::submit`, sound to `audio::push*`, status through `report`.
2. define one `Driver` in it: an id prefix, the vendor's name, a hint for when their software is missing, and
   the `list`, `make` and `watch` functions.
3. add it to the table in `src/source.mm` behind a build switch like `MEYRA_DECKLINK`. sdk headers go in
   `vendor/<name>/`, their licence in `THIRD_PARTY_NOTICES.md`.

> [!IMPORTANT]
> menus, the source picker and settings pick a new driver up from that table. load the vendor's library at run
> time, so the app still starts where it is not installed.

## some numbers

counted on 2026-11-22, for v0.3.0. the runs are the ones that left a log behind, so they are a lower bound.
the counts of upscalers and frame generators are newer: counted again in the source for v0.5.0.

| | |
|---|---|
| 1,270 | test runs of meyra, 5 hours of playback |
| 790,000 | frames drawn in them |
| 260,000 | of those made up by a frame generator |
| 9,687 | lines of source and shaders, comments and all |
| 25 | shader functions |
| 38 | nets in the box, 34 of them our own |
| 665,185 | weights in our own nets. the smallest has 1,321, the largest 93,089 |
| 10 | presets. 6 upscalers (hashed filters experimental), 3 frame generators (the second one and block matching experimental), 7 ways to compare before and after |
| 0.6 ms | from a frame's arrival to its present call, frame generation off |
| 11x | faster building of a big net's shaders (7.3 s to 0.66 s) |
| 88 of 88 | test pictures unchanged, bit for bit, with every new switch off |

tried and thrown out along the way: guessing the next frame instead of making one in between (jittery, fuzzy,
tree trunks waved), smoothing the motion field (no difference), a cleanup filter that made the picture mushy, and nets
that learned from ps5 pro pictures and only blurred.

licence and copyright: see [README.md](README.md#licence) and `LICENSE`.
