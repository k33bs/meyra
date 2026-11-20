# changelog

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
