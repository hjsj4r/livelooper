# Custom sample banks

Each subfolder here becomes a SuperDirt sound name. Files inside are addressed by
index (`:0`, `:1`, ...).

```
samples/
  mykick/
    0.wav
    1.wav
  mysnare/
    0.wav
```

Then in Tidal:

```haskell
d1 $ s "mykick mysnare mykick:1"
```

Loaded automatically by `startup.scd`:

```supercollider
~dirt.loadSoundFiles("D:/livelooper/samples/*");
```

- WAV / AIFF / FLAC, **44100 Hz** preferred (matches the H8 — no resampling).
- Reload after adding banks without restarting: re-run the `loadSoundFiles` line above.
- The folder name is the sound name; `mykick/0.wav` → `s "mykick"`.
