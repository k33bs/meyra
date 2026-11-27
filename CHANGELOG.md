# changelog

## v0.6.0

released: 2026-11-27

frames at any rate, side bars that are not black, a way round usb cards that send too few frames, and a debug
report to paste. the new switches are all experimental and off unless you turn them on.

- fixed: v0.5.0 with game mode in full screen switched off edited its own bundle (it took the game mode keys out of
  its `Info.plist`). that broke the app's signature, and macos then refused it the camera without asking, while the
  switch in system settings still showed on. every start put the edit back, so even a fresh copy broke itself again.
  game mode off is now macos' own per-app switch (the one in the game mode item in the menu bar), a flag outside the
  app, and the app is never edited. updating heals it: the update is a fresh, signed bundle, the old setting carries
  over as the new flag, and a copy edited by v0.5.0 is put back when the original was kept. if the signature is
  broken anyway, the camera message says so and what to do.

- motion > output rate: how many frames a second go to the screen and when, instead of one made frame between two
  real ones. every signal tick, every screen refresh, fixed 30 / 50 / 60 fps, times 2 / 3 / 4, times 2 following the
  gap, source rate. block matching makes a frame at any point between two real ones; apple's and the second generator
  only the middle, the other slots then show the nearer real frame (the overlay says so). needs frame generation on,
  so macos 26. the frames go up no faster than the screen refreshes: a times mode the screen cannot take is thinned,
  down to real frames only. every screen refresh leaves the display at its own rate and greys match display refresh.
  while more than one frame in ten is made, the enhance net after generation, apple super resolution and stabilise
  step aside, and the schedule, deadline and late frame switches decide nothing.
- output rate > blend in-betweens instead of generating: a cross-fade of the two real frames by time. no motion to get
  wrong, softer, little gpu.
- output rate > real frames (fewest, some, more, all): where the screen's rate is not a whole multiple of the game's
  (30 on 100 hz, 25 on 60), how many pictures go up as themselves rather than as a made frame a little off their time.
  default some.
- output rate > ride out dropped frames (one, two, three ticks: +17, +33, +50 ms at 60 hz): delay held on purpose, so a
  game frame that comes late is still in time and the gap is filled with made frames at even steps. no hold, no
  catch-up. the price is that delay all the time. a frame a tick late (50 ms at 30 fps) needs one tick, a missed one
  (66 ms) two.
- output rate > even out the game's late frames: with ride out on, a late game frame is shown one frame's step after the
  one before, not by when it came, because most 30 fps games move a fixed step a frame, late or not. takes out a
  rattle on near detail while turning. the costs are real: about a tick and a half more delay at the same ride out,
  nearly every frame on screen is a made one, the sound is not stretched so lips can drift up to about 30 ms either way
  for a moment, and a game that moves by the time passed gets the rattle instead. tried on one game so far.
- output rate > enhance the made frames too: the enhance net keeps running while made frames go up, on every frame.
  steps aside for 15 s (longer each time) when the gpu cannot keep up.
- motion > frame generator, six more switches for block matching: find small fast things, go soft where the match is
  bad, take one side, steady, keep the followed character whole, show a real frame across a cut, made frames as sharp as
  real ones. go soft and the real frame across a cut only act with an output rate and are grey without one. block
  matching with all six off makes the same bytes as in v0.5.0 at the same gpu time; their kernels and memory are set
  up only once one is on (what stays: about 1 mb at 1080p, 4 at 4k).
- picture > side bars: what the window leaves around the picture can be grey, a dim glow from the picture's edge, or
  the glow with what the picture showed there a moment ago. brightness and softness steps. the picture itself is not
  touched, snapshots and recordings leave the bars out.
- side bars > fill the window with letterboxed pictures: a wide cutscene with black bands, steady for a second, is made
  larger so the band fills the window. lets go at once when anything shows in the bands.
- side bars > stretch a third, two thirds, to fill: the picture grows into the side bars, true in the middle, wider
  towards the edges.
- source > format > layout: where the device offers its format compressed as well, uncompressed (least delay, as
  before) or compressed (mjpeg). some usb cards only reach 60 fps compressed. per source, also in choose source. the
  format meyra opens by itself is marked (default).
- when a capture card delivers well under its format's rate while the mac keeps up, the overlay says so and what to try
  (compressed, a lower format, a usb 3 port without a hub). the motion line and cadence say it too. cameras are not
  watched, and a card that evenly passes a 24 to 50 fps signal through gets no hint.
- system capture reads back what macos really runs after the start and a second later (size, pixel layout, rate) and
  sets it once more if it differs; if it still differs, the hint says so instead of blaming the card. every second the
  log gets a capture line: frames from the device, their timestamp spacing, avfoundation's drops by reason, buffers
  without a picture. the overlay shows a mismatch or drops only when there are some.
- help > copy debug report: the mac, its screens, the capture devices and their formats, what runs now with the
  capture counts, the capture start lines kept apart (asked, what macos ran, set again, first frame), camera and
  microphone permission and whether the signature holds, and the changed settings, as text on the clipboard. no
  names, serial numbers, mac addresses or folders. `--debug-report` prints the same and quits.
- help in one place: the readme's new help section goes symptom by symptom (tearing, stutter, too slow, delay, no
  picture, colours, sound, …) with the menu item or key for each; the manual's table points there. help > common
  problems and fixes opens it, help > discord opens the discord, and the no-picture message names the first.
- `--list-devices` lists, under each system capture device, every pixel layout it reports per size and rate. names are
  cleaned and ids shortened to a short id and a hash; `--list-devices --ids` prints the raw ids for `--source`.
- hidden test switches for system capture, for a card that stays short of its rate: `-avfEarly`, `-avfKeepLock`,
  `-avfReapply always|NO`, `-avfOut 420v|420f|native`, `-avfAll` (see the manual). none set: the usual start.
- the status overlay has rows for all of the above, an `out` line with what went up each second (real, made, nearer
  real, late, held, left out), the delay held for drops, and "the output rate decides" on the rows it overrides. the
  order line names side bars, letterbox crop and side stretch.
- presets: the built-in ones turn the output rate off and put its switches (blend, real frames, ride out, even out,
  enhance made frames) and the six block switches back to their defaults, so a key always gives the same thing. your
  own presets keep what they saved; one saved before v0.6.0 gives these their defaults. side bars are left as they are.
- output rate > source rate is now "source rate (real frames only)", apart from match display refresh's source rate.
- known limit: ride out on 60 fps content raises the delay a refresh for a moment after a picture comes a few ms late
  (see the manual's known limits). 30 fps games are not affected.
- known limits of the output rate, all in the manual: every screen refresh on clean 60 fps still holds a slot now and
  then and its delay saws between about 16 and 45 ms; times 2 on 60 fps on a 100 hz screen makes no frames but adds
  about 16 ms, and with variable refresh its uneven gaps count is wrong; the overlay can say frame generation is idle
  while a rate works; full screen in or out costs a hitch of about half a second; very uneven sources swing the delay
  by tens of ms. not new: on a still picture with frame generation on, the sound can jump about 0.2 s late for a moment.
- licence: the notices name macframegen and metalgoose for the output rate's methods. the still rules "by motion against
  contrast" (since v0.3.0) are now credited as what they are: a port of metalgoose's stability blend, gpl-3.0 version 3
  only, with a comment in the shader. side bars and the newer block switches have their lines too.

## v0.5.0

a third frame generator, a sixth upscaler and a few more switches to try. all experimental and off unless you turn
them on.

- motion > frame generator > block matching: a third generator, no files to install, picked in the menu (the I key
  still goes round apple's and the second one). blocks are matched on the gpu from coarse to fine and the two real
  frames are moved and mixed along the vectors. edges of moving things can tear. when it cannot start, apple's takes
  over.
- two switches for it, under motion > frame generator: find the whole picture's shift first, for faster pans, and take
  one side where the frames disagree, instead of a double image.
- picture > upscaling > hashed filters: a sixth upscaler, menu only. per pixel one small trained filter from
  ravu-lite's table, picked by the edge under it, makes the picture at twice the size, which is then brought to the
  window. can look softer than metalfx. without a usable table it scales plain and says so in the log.
- picture > stabilise: the frame before, moved along the picture's motion, is mixed in a little. meant to steady
  edges, the effect is small. it steps aside while frames are generated.
- picture > grain: fine grain in the last pass, strongest in dark and mid tones, light to full. meant to cover the
  plastic look of areas that were cleaned out.
- motion > skip only after a lasting backlog: without generated frames, a repeat is left out to catch up only once the
  screen has been behind for half a second, not after one slow frame.
- meyra menu > take the screen buffer late: the screen's buffer is asked for after the frame's gpu work is written
  down. costs gpu time (about twice the work in one test), whether it buys delay is not measured yet.
- meyra menu > two screen buffers instead of three: one frame less can queue before the screen. can stall when a frame
  takes long.
- the status overlay lists the new switches with the others, and stabilise has its own gpu time on the stages line.
  presets turn the new picture and motion switches off.
- the readme is a short one now, to get going. the full reference, every switch with its numbers and caveats, moved to
  MANUAL.md.

## v0.4.1

- show hud areas: the outlines are only on the picture while the status overlay is on, compact or with every switch.
  with the overlay off the picture is clean. they still show while marking and for a moment after.

## v0.4.0

recording, and a switch that turns meyra off without closing it.

- recording (tab): what is on screen goes to a .mov in movies/meyra, hevc from the mac's video encoder, with the sound
  as it is played. the screen never waits for it: when the encoder or the disk fall behind, the file loses a frame, the
  screen does not. a red dot and a counter sit in the corner meanwhile and are never in the file.
- keep the last 30 seconds (shift + tab): held in memory all the time, already encoded, and tab writes them to a file:
  for what just happened. an amber dot in the corner, white for a moment after a save.
- recording menu: size (at most 1080p unless set otherwise, a bigger picture is scaled down on the gpu first), bitrate
  (by size, or 10 to 100 mbit), overlay and hint lines in the file or not, open recordings folder.
- the file carries the tone curve of the colour setting, so a player shows it the way the window did.
- meyra menu > turn meyra off: the capture device is let go and nothing is drawn, generated or played. the window and
  the settings stay, the same item turns it on again.

## v0.3.1

fixes: two picture faults in generated frames, and what a review of v0.3.0 found.

- generated frames: the green line along the bottom (and top) edge is gone. the interpolator's colour collapses only
  part of the way in the outermost rows, above the limit of the repair that was there; those rows now take the real
  frame's colour where both channels are clearly under it. last two rows green: 7.6% of pixels before, 0 after.
- generated frames with the still rule "by motion against contrast, allows for dither" (the gta6 everything preset):
  no more specks. single pixels of moving things passed for still and took the real frame's pixel. 336 a frame
  before, 10 after.
- the audio trim key also works by its place, for keyboards whose apostrophe sits on a number.
- keys: the letter a key types comes before the slash's place, so z is passthrough again on dvorak and the full stop is look
  on turkish and russian keyboards. / also works by the character.
- a stored setting below zero (upscale -1) no longer crashes the app a second after the first frame. every numbered
  setting wraps the same way, sharpen is kept between 0 and 1.
- the second generator: a download that ends after something else was chosen no longer switches to it. a bad offset in
  its json is refused instead of read. frames that keep failing stop it after three new sessions (it restarted for ever).
  a start that failed is tried again after the next gap, not only when it is chosen again.
- presets also hold the shrink method, apple sr with frame generation and its edge padding: a preset gives the same
  picture every time, and changing one of the three shows as (changed). presets saved before get the defaults for them.
- hud areas cannot be marked while the compare view shows the picture twice or in strips: the area landed elsewhere.
- tolerant repeats does nothing in passthrough, as the menu says.
- with the noise filter and real frames only, the net no longer runs on the raw frame ahead of a filter that is not
  through. the interpolator is not handed a noise filter buffer that is still being written.
- no dither removal pass on the run ahead with the net first, no shrink for the generator while frame generation is off.
- chain E:SU with a 2x net: the upscaler runs when sharpen-first has brought the picture back to the source size.
- a net file with a weight below 1.2e-38 loads.
- window > show status overlay hides the overlay again (h still goes off, compact, every switch).
- a frozen frame under a chain goes through the chain as it is now. the order line names the shrink with a look on, the
  compare strips call it shrink. the generator's peak time starts over with another generator or size.
- net names with umlauts read right in the menu and the log. --set enhance=N holds. restore built-in presets clears the
  (changed) mark. compare and presets have their own tooltips. the passthrough texts say that one repeat is left out
  when the screen's queue has backed up.
- under a chain the overlay and order line follow the chain for the noise filter. a new source starts the capture clock
  over. the hud area count does not drop to zero while a preset loads. the render thread no longer looks at the disk.
- tools/mpv2net.py reads e+ and E exponents and checks how many numbers a constructor holds.

## v0.3.0 (dev release)

- the gta6 enhance nets ship with meyra (24 more), and realesr-general-x4v3 for still pictures. the readme says what each was
  trained on. a net in the nets folder with the name of a shipped one is left out, n passes the slow one by.
- the second generator's files can be downloaded on request (return while it is chosen, or the menu), after saying what their licence allows.
- the readme says how to add your own weights.
- an app icon.
- presets 8, 9 and 0 use a net trained on gta vi and say so in their name. presets > remove my preset removes one you saved.
- the readme says at the top what meyra is for and what it is not.
- compare (/) has five ways to show the original against the result: cut left / right, above / below or diagonal, side by side, stacked. shift + / goes back. the original's half keeps the game's own frame rate.
- space freezes the picture on the newest real frame, every switch but the noise filter still acts on it: for comparing without motion.
- look (., picture menu, off, experimental): a tone curve and colour factor fitted on before / after videos of gta vi
  with the dlss 5 look, in three strengths. brightness and colour only. daylight gets duller with the strong one.
- compare stages (/, window menu): the picture after every stage of the chain as strips, or the same strip from each.
- enhance nets trained on gta vi footage have gta6 in front of their name.
- licence: modified versions must be marked as such, the name "meyra" is not licensed (gpl section 7), and the readme
  says what closed source products and code agents may not do with the code and the weights.
- weights of your own in `~/Library/Application Support/Meyra/nets/` are listed after the ones that ship.
- full screen with the window's resolution keeps the picture's ratio (an ultrawide got it stretched), and w steps
  the size it renders at there.
- second code review: a 1x enhance net, apple super resolution and frame generation together made the net flicker
  (it ran on 44 of 60 frames), super resolution now steps aside there. compare view: no blinking in turns, right names,
  whole pixels, on the slash key's place (it overwrote preset 7 on german and other layouts), off in passthrough.
  the chosen net is kept by name, so new files in the nets folder do not change it. the deadline row, w on tall
  screens, a screen whose rate is changed while meyra runs, and a half precision net that will not build.
- code review: the pipeline is not rebuilt on every call without a drawable, apple super resolution only steps aside
  for a 2x net that is ready, the number row works on azerty, net files sort by number, the noise filter's status
  is per size, negative stored values no longer index out of range.
- enhance nets build faster: every layer is its own shader library and they compile side by side, pipelines too.
  a cold build of a 6x16 net 0.76 -> 0.19 s, of a 12x32 net 7.3 -> 0.66 s. the pipelines are also kept in
  `~/Library/Caches/<bundle id>/nets` (named by a hash of the generated source, the gpu and the os build); a
  missing, broken or stale file just means a normal build. the picture is the same bit for bit.
- half precision for enhance nets (enhance menu, off): layers of up to 24 features do their sums in half. one run
  a frame: 1.2x on 4x8 nets, next to nothing on 6x16 (1.04x), 1.25x on 8x24, 12x32 left in float (slower in half). within one
  level of 255 of the float picture.
- generate at (t, motion menu) has two sizes between full and 1280×720: 1536×864 and 1344×768, for apple's
  interpolator. a saved "generate at 720p: on" still means 1280×720.
- generated frame deadline (motion menu, default by the slowest = as before): by the usual waits for a generated
  frame as long as 95 of the last 100 took plus 2 ms, with no 12 ms floor. early schedule only.
- show late generated frames a refresh later (motion menu, off): on screens faster than the source (100, 120 hz,
  variable refresh) a generated frame that misses its moment goes up when it is done, a refresh before its real
  frame, instead of being left out. no room for that at 60 hz.
- keep the gpu awake (meyra menu, off, uses more power): a tiny job stops the gpu clocking down between frames.
  second generator 6.6 -> 4.1 ms a frame, a 6x16 enhance net 7.3 -> 4.4 ms. only while meyra is in front with a
  picture and a net or the second generator is on.
- hud areas (q, motion menu): mark up to 8 rectangles on the picture that always show the real frame in
  generated ones: a minimap, a health bar, subtitles. kept as parts of the picture (`hudRects`), so they fit any
  window size. clear hud areas forgets them, show hud areas outlines them. with every still rule, hud lock,
  both generators and generate at 720p. on a 60 fps clip with a still, opaque overlay: the overlay's own pixels
  come out exact under every rule (without: exact under three rules, 61 db soft, 29 db with no rule), its
  edges 28.8 db (24.6 to 31.3 without), and the game picture inside the rectangles drops from 32.6 to 24.5 db,
  because it moves at 30 there. so mark tight.
- plain passthrough sheds a backlog in the display's queue like frame generation off does (one exact repeat
  left out). it was exempt and stayed two to three refreshes behind after the display changed mode at start.
  hidden `-drain NO`: as before.
- frame generation on and a picture that was already still when generation came up (or when a switch
  restarted the schedule): nothing was drawn until it moved, so the overlay and the hint line stood still.
- below 30 fps on the tick: a frame held three signal frames was counted twice for the delay, which read up
  to 8 ms long at 20 fps (the audio follows that number). the frames shown are the same.
- presets: the preset's number stays up until one of its own switches changes, a saved preset keeps its
  enhance net by name, the hint says when the second generator's files or the net are not there, restore
  built-in presets says so in the log, the number row works by where the keys are, and the log has a
  `preset N applied:` line with every switch.
- presets on the number keys (standard, untouched, fastest, smooth, ...), shift + number saves your own over one.
- overlay in two sizes (h): the steps as they ran and one line of numbers, or every switch in three columns. hints
  stay until the next key.
- frame generator (i, motion menu, experimental): a second generator can make the frames in between instead of
  apple's interpolator. it is a small flow net on the gpu, working at 480 or 720 lines, and it is not part of
  meyra: it runs only when its three files are in `~/Library/Application Support/Meyra/flyhighfg/`. without them
  the switch says so and apple's stays in use. default: apple's, unchanged.
- three experimental picture switches, all off by default: enhance real frames only (o), steady enhance (y),
  supersample (u). see the readme. the stats line and the overlay say for each whether it acts or why not
- enhance (n, picture menu, off by default, experimental): a small neural net as shader passes on every frame,
  at any window size. fsrcnnx 8-0-4-1 and artcnn c4f16 (plain and denoise + sharpen) included; a weights file
  dropped into `resources/nets` is one more.
- still areas in generated frames (motion menu): three more rules for taking unmoved pixels from the real
  frames, so huds and still backgrounds stop shimmering. default is the old exact match.
- generate at 720p (motion menu, off): apple's interpolator on its fast path, about 4 ms instead of 11, softer.
- four experimental switches (l k p j, all off): hud lock (what stands still for a second keeps its real pixels
  in generated frames, ported from pushfps), cut test (coarse picture + histogram, flashes let through),
  tolerant repeats (noisy usb cards), capture clock (presents planned from capture timestamps).
- noise filter (picture menu, off): apple's temporal filter on real frames. about 10 ms a frame, subtle.
- full screen can keep the window's resolution and scale it to the screen (x), instead of rendering at the
  screen's size.
- overlay says which upscaler is chosen when it is idle (window no larger than the source, passthrough).

## v0.2.1 (dev release)

- frame generation off: repeated frames are shown, so each frame of a 30 fps game stays up two refreshes.
  skipped they came out uneven and looked choppy. one repeat is left out only when the display's queue has
  backed up.
- passthrough leaves nothing out: repeats and rolled frames are shown as they came.

## v0.2.0 (dev release)

- picture: apple super resolution as a third upscaler (macos 26), next to plain and metalfx. off by default.
  runs with frame generation too: the two take turns on the neural engine, which costs about 9 ms of delay.
- variable refresh: full screen on a screen with adaptive sync or promotion, meyra leaves the mode alone and lets
  the screen follow the source. about half the delay of the matched 60 hz mode, and passthrough shows every
  frame again there.
- apple super resolution: mirrored padding around the tiles against ringing at the picture's edges (on, in the
  upscaling menu).
- colour switch (c): bt.709, srgb or the screen's own colours. levels detection starts over when the signal
  changes format (an xbox going to 720p stuck on full range and looked washed out).
- window size key (w: 720p, 900p, 1080p, ...), vsync switch (v), game mode switch, and the overlay names the key
  next to each setting.
- fixes from a code audit: a generated frame from an older pair could be shown (motion stepping back), a game
  frame was lost when drawing fell a tick behind, small changes on a still picture did not show with frame
  generation on, fast vertical pans were dropped as broken frames, the screen could sleep mid-game, colour sat
  half a pixel to the right.
- blackmagic: an rgb signal (an xbox at 720p) gave a black picture. it is now captured as rgb and converted.
- more from the audit: a capture format change that fails is retried and then shown as an error (was only
  logged), frame generation and super resolution that fail every frame get a new session instead of sitting
  there "ready", sd sources use bt.601 colour, a loud surround mix is turned down instead of clipped, the
  generated-frame green repair leaves real greens (grass) alone, the microphone question no longer freezes the app.
- updater: no links in the download, a limit on what it unpacks to, checks off the main thread, and the game
  mode switch keeps the signed Info.plist so a kept previous version still verifies.
- picture: two edge-aware shader upscalers, amd fsr 1 (the easu pass) and snapdragon gsr 1. both work with frame
  generation and pick up less grain than metalfx.

## v0.1.0 (dev release)

first version.

- capture from any device macos can see, an optional vendor driver for blackmagic decklink and ultrastudio
  devices, and a replay source of raw frames.
- picture: automatic levels (video or full range), dither removal, metalfx upscaling, luma-only sharpening.
- frame generation for 30 fps games on a 60 hz signal (macos 26), on the tick or early.
- the source's audio played in step with the picture.
- display refresh matching, rolled-frame drop, status overlay, snapshots.
- updates from the project's github releases, checked at launch, with revert to the previous version.
