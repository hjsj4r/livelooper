# Live Looper — TidalCycles + SuperCollider

Music coding + live guitar looping, tightly synced. **TidalCycles** generates the
patterns; **SuperCollider** runs SuperDirt (drums/samples), the guitar loopers, and a
tempo-locked click. A **DualSense** controller drives the loopers hands-free, and the rig
runs on whatever audio interface is plugged in — pick it from the dashboard.

> Migrated off Strudel — no browser, no `node server.js` OSC bridge. Tidal sends OSC
> to SuperDirt directly over UDP.

## Architecture

```
TidalCycles (Haskell, code)  ──OSC──►  SuperCollider
                                         ├─ SuperDirt   (drums / samples)
                                         ├─ Loopers     (guitar, cycle-synced)
                                         ├─ Click       (panned RIGHT — L/R hack)
                                         ├─ Devices     (scan interfaces, switch live)
                                         └─ Dashboard   (DualSense + browser UI)
                                       → any interface. On the ZOOM H8:
                                                   L = music → PA (mono cable)
                                                   R = click → your headphones
```

## Requirements

- SuperCollider 3.13+ — installed
- SuperDirt quark — installed
- ZOOM H8 as ASIO device @ 44100 Hz
- TidalCycles + VS Code `vscode-tidalcycles` — **installed in step 6 (not yet)**
- *(for VST instruments)* the **VSTPlugin** extension in `%LOCALAPPDATA%\SuperCollider\Extensions`
  and at least one plugin — Surge XT is installed under `D:\vst`. See *VST instruments*.

## Daily startup

1. Open **SuperCollider**, open `startup.scd`.
2. Click inside the parens and press **Ctrl+Enter** — one evaluation does everything.
   Wait for `=== LIVE LOOPER READY ===`.
3. VS Code → `Tidal: Boot`.
4. *(optional)* Dashboard: in a terminal, `cd dashboard` then `node server.js`, and open
   **http://localhost:3000**. No `npm install` needed.
5. **Setup → Tracks → Add track** for each thing you are looping. A session starts with
   **no tracks**; each one is added on the jack you choose, and the meter beside it shows
   the signal, so there is nothing to map by hand. Save writes the layout to `config.scd`
   if you want the rig to boot with it next time. (Saving whole sessions is planned.)

Re-evaluating step 2 is safe and fast: it reloads the code without re-scanning the sample
library and without interrupting audio. Use it to apply an edit mid-session.

Quick audio check:

```supercollider
{ SinOsc.ar(440) * 0.1 ! 2 }.play;   // 440 Hz tone — Ctrl+. to stop
```

## Configuration

**Everything you'd change for a different rig lives in `config.scd`** — audio device,
sample rate, channel counts, track inputs, loop length and join, click tuning,
ports. No other file should need editing to move to new hardware.

The project folder path is derived from `startup.scd`'s own location, so you can move or
clone the folder anywhere.

| Change | Then |
|---|---|
| Track inputs, click, loop length and join | re-evaluate `startup.scd` |
| Audio device, sample rate, channel counts | dashboard → Setup → Apply, or `~rebootRig.();` |
| Tracks: add / remove / re-wire / rename | dashboard → Setup → Tracks, no restart |
| Added a sample bank to `samples/` | `~reloadSamples.();` |
| Need a Dirt-Samples bank you trimmed out | `~loadBanks.([\tabla]);` — no restart |

`~sampleBanks` lists the Dirt-Samples banks to load at boot — just `[\bd]` for now, as an
example. Add banks as the set grows; `nil` loads the whole library (219 banks, ~450 MB,
~30 s), and since a device switch is a boot too, that cost is paid on every switch.
`~dirt.postSampleInfo;` shows what is loaded.

The dashboard binds to **localhost only**. It can record, clear and re-level your tracks,
so it shouldn't be reachable from a venue's WiFi by default. To use it from a tablet on
stage, start the bridge with `DASH_HOST=0.0.0.0 node server.js`.

If the configured audio device isn't present, startup **stops with a readable error**
naming the device and listing what SuperCollider can actually see, rather than hanging on
a boot that never completes.

Don't know which SC input index a physical jack is? The H8's ASIO order is not a simple
sequence — map it rather than guessing:

```supercollider
"D:/livelooper/tools/input-scan.scd".load;   // play into one jack; stop with ~inputScanStop.()
```

## Files

| File | Purpose |
|---|---|
| `config.scd`   | **All settings** — device, tracks, loop join, click, ports |
| `startup.scd`  | One-evaluation boot: server + SuperDirt + everything else |
| `devices.scd`  | Lists the audio interfaces (with channel counts) and moves the rig onto one |
| `looper.scd`   | Multitrack loopers (one per input) + faders + FX |
| `click.scd`    | Tempo-locked click, right channel |
| `vst.scd`      | VST instruments hosted in the server, played from Tidal and a MIDI keyboard |
| `settings.scd` | Config values editable from the dashboard, and written back |
| `acid.scd`     | sawtooth + supersaw + subkick, and a sidechain ducker |
| `dashboard.scd`| Streams state to / takes commands from the web dashboard |
| `dashboard/server.js` | Pure-Node bridge (SC ↔ browser). Run: `node server.js` |
| `dashboard/index.html`| The web dashboard UI |
| `BootTidal.hs` | Tidal boot (SuperDirt target, tuned latency) |
| `samples/`     | Your custom sample banks |
| `tools/input-scan.scd` | Maps a physical jack to its SC input index |
| `tools/sync-check.scd` | Diagnoses loop timing / tempo mismatches |
| `tools/click-calibrate.scd` | Verifies the beat-grid anchor; `~clickOffset` should be 0 |
| `tools/loop-inspect.scd` | Reads a recorded loop back and finds holes in it |
| `tools/latency-measure.scd` | Measures the audio round trip, for `~loopOffset` |
| `test/nav-test.scd` | Regression test for selection + level control |
| `test/select-test.scd` | Regression test for pins, stop/start, and settings |
| `test/acid-test.scd` | Regression test for the acid synths and the ducker |
| `test/panic-test.scd`  | Regression test for Ctrl+. recovery (see below) |
| `test/looper-test.scd` | Regression test for the record path + signal path |
| `test/dashboard-test.scd` | Regression test for the dashboard message rate |
| `test/stereo-test.scd` | Regression test for stereo (two-input) tracks |
| `test/fx-test.scd` | Regression test for the per-track FX chain |
| `test/join-test.scd` | Regression test for loop length + the head fade and tail |
| `test/layout-test.scd` | Regression test for add / remove / re-wire / rename + saving the layout |
| `test/devices-test.scd` | Regression test for the device scan and a live server switch |
| `test/vst-test.scd` | Regression test for VST instruments (needs VSTPlugin + Surge XT) |

## Roadmap

- [x] **1. Scaffold + consolidated `startup.scd`** (boot + SuperDirt + samples)
- [x] **2. Looper in `looper.scd`** + clear-during-record fix (generation token)
- [x] **3. Click in `click.scd`** — tempo-locked, right channel
- [x] **5. Input mixer** — record the sum of enabled H8 inputs (`~setInput.(ch, 1/0)`)
- [x] **6. TidalCycles** as sequencer (BootTidal.hs, oLatency tuned, click synced)
- [x] **7. Ctrl+. survival** — panic stop rebuilds the rig instead of ending the set,
        loops re-enter in phase. Covered by `test/panic-test.scd`.
- [x] **11. Sample library on a diet** — `~sampleBanks` loads only the banks a set needs
        (219 banks / 450 MB / 14 s → 3 banks / 5 MB / instant), and `~loadBanks.()` pulls
        more in mid-session without a restart.
- [x] **10. Dashboard costs ~nothing idle** — the browser now gets a clock *reference*
        twice a second and extrapolates phase in `requestAnimationFrame` (smoother than
        the old 30 Hz push), and discrete state is sent only on change: measured
        **7 messages per 4 s instead of 240**. Preview no longer recompiles a SynthDef
        per click; the bridge binds to localhost. Covered by `test/dashboard-test.scd`.
- [x] **9. Zero-cost hot paths** — tempo tracking reads SuperDirt's already-parsed event
        (`receiveAction`) instead of re-scanning every OSC message; loop buffers are
        pre-allocated mono at the `~minCps` worst case so hitting record never allocates
        and never waits on the server. Covered by `test/looper-test.scd`.
- [x] **8. Single-source config + one-evaluation boot** — `config.scd` owns every
        setting, project path is derived (folder is portable), `s.waitForBoot` replaced
        the two-region dance and the fixed-delay timing hacks, and a missing audio device
        now fails with a readable error instead of hanging.
- [x] **4. UI dashboard** — metronome and **multitrack strips** (per-track
        record/overdub/clear + fader, click a strip to select it). The sample browser it
        once had is gone; Tidal's editor is where samples get auditioned.
- [x] **12. Any audio interface** — the dashboard scans every device the machine can see,
        *with* its input/output counts (from a throwaway `scsynth`, since the sclang API
        only knows names), and switches the running rig onto one: a server quit + boot
        through the same path as the first boot of the day. Tracks are **built from the
        dashboard** — add, remove, re-wire, rename, up to `~maxTracks` — and Save writes
        the layout and the device back into `config.scd`. Perform / Setup views, input
        meters on every strip, a loop play head, keyboard shortcuts. Covered by
        `test/layout-test.scd` and `test/devices-test.scd`.
- [x] **13. VST instruments** — Surge XT (or any VST2/VST3) hosted inside scsynth via the
        VSTPlugin extension, played from Tidal (`# s "surge"`) through SuperDirt's own MIDI
        event type and from a MIDI keyboard, with the plugin's editor a button away. State
        is snapshotted so it survives `Ctrl+.` and a device switch. Covered by
        `test/vst-test.scd`.
- [x] **14. Looping MIDI instruments** — a track's source is a jack OR an instrument, so
        playing a phrase on the keyboard and looping it is the same gesture as looping a
        guitar. The looper reads an absolute bus (a jack is just `NumOutputBuses + jack`),
        instruments run in `~srcGroup` ahead of the loopers so a take cannot record the
        silence of a not-yet-written bus, and an unresolved instrument reads a dedicated
        silent bus rather than the master. Covered by `test/vst-test.scd`.

## How loops line up

A loop is `~numLoopCycles` cycles long, and one Tidal cycle is one measure (with
`~clickDiv = 4`). So the default of 4 gives a **4-measure loop**.

Recording starts on the **next measure** — `~recordQuantize = 1`. You never wait for a
phrase boundary, because the loop buffer is locked to the phrase grid rather than to the
moment you punched in: buffer position 0 always means "phrase downbeat", and arming
halfway through a phrase simply starts writing halfway into the buffer (`Phasor`'s
`resetPos`). Every loop therefore stacks with every other one no matter when it was
armed, and a panic restore can re-enter on any measure instead of waiting for the loop's
own boundary.

The post window shows both facts when you arm a track:

```
[t0 in9] waiting 0.5s for cycle 1 (phrase pos 25.0%)...
```

The beat grid is anchored to when a pattern event **sounds** (`ev[\timeStamp]`), not when
its OSC message arrives. Tidal sends events ~220 ms ahead, so anchoring to arrival ran the
whole grid that far early: recording opened before the downbeat, captured silence at the
head, and clipped the same amount off the tail — an audible hole exactly at the punch-in
point. If a loop ever sounds like it has a gap, that is what to suspect:

```supercollider
"D:/livelooper/tools/loop-inspect.scd".load;
~loopInspect.(0);      // reads the loop back and reports any silent regions
```

## Panic — Ctrl+. is safe

`Ctrl+.` (CmdPeriod) is SuperCollider's panic stop. It clears both clocks, frees every
non-permanent OSC/MIDI responder, and frees **every node on the server**. Left alone,
that means one panic stop ends the set: no click, no dashboard, no loopers,
and Tidal silent for good (SuperDirt rebuilds its orbits, but they feed a bus whose
master fader is gone).

The rig now registers everything it needs to come back:

| Mechanism | Brings back |
|---|---|
| `.fix` on every responder | tempo tracking, dashboard commands |
| `ServerTree` hooks | Tidal master fader, looper track synths |
| `CmdPeriod` hooks | click scheduler, dashboard state streamer |

**Loops survive.** `Ctrl+.` frees nodes but not buffers, so the recorded audio is still
in memory — any track that was `playing` or `overdub` is re-armed and re-enters **on its
own loop boundary**, in phase with the patterns. A take that was still `recording` is
discarded to `idle`. To make panic mean total silence instead, set in `config.scd`:

```supercollider
~restoreLoopsOnPanic = false;
```

Verify it after changing any of these files (headless, **no ZOOM H8 needed** — it boots
the system default device):

```powershell
$sc = "C:\Program Files\SuperCollider-3.14.1\sclang.exe"
& $sc -D d:/livelooper/test/panic-test.scd       # 26 passed
& $sc -D d:/livelooper/test/looper-test.scd      # 34 passed
& $sc -D d:/livelooper/test/dashboard-test.scd   # 50 passed
& $sc -D d:/livelooper/test/nav-test.scd         # 29 passed
& $sc -D d:/livelooper/test/stereo-test.scd      # 15 passed
& $sc -D d:/livelooper/test/fx-test.scd          # 19 passed
& $sc -D d:/livelooper/test/join-test.scd        # 44 passed
& $sc -D d:/livelooper/test/select-test.scd      # 65 passed
& $sc -D d:/livelooper/test/acid-test.scd        # 40 passed
& $sc -D d:/livelooper/test/layout-test.scd      # 80 passed
& $sc -D d:/livelooper/test/devices-test.scd     # 42 passed  (boots its own server twice)
& $sc -D d:/livelooper/test/vst-test.scd         # 79 passed  (needs VSTPlugin + Surge XT; skips otherwise)
```

None of them needs the H8, and **they're safe to run while your rig is booted** — each
uses its own server port and builds SuperDirt without its sample library, so they take
seconds rather than minutes.

> Note: re-evaluating `looper.scd` **does** clear the loops (buffers are freed to avoid
> leaking them). Reloading a file is an authoring action; `Ctrl+.` is the live one.

## Selection: focus plus pins

The **focus** is where the stick is. Navigating moves it, and it is always part of the
selection. A **pin** parks a track in the selection so that navigating away does not drop
it — press **✕ Cross**, or click the dot on a strip.

```
selection = pinned tracks  +  the focused one
```

So there is no mode to enter or get stuck in: pin as you go, and the transport buttons
(record / overdub / clear / stop-start) fire on everything selected. Unpin with ✕ again.

The **level** deliberately does *not* follow the selection — a fader ride is a continuous
gesture you want aimed at one thing, so left/right always moves the focused item alone.

Pinned strips get a purple left edge; the focused one gets the blue border. Both at once
is normal and looks like both.

## Stopping and starting a loop

The **touchpad** silences the selected loops and brings them back, quantized to the next
bar. The badge reads `STOPPING…` or `STARTING…` while the toggle is armed, and pressing
again before the bar line cancels it rather than queueing a second one.

Nothing is lost: the buffer stays, and the play head keeps running through the silence —
only the output is muted. That is why any bar line is a safe re-entry. The loop always
comes back exactly where it would have been, so it can never return flammed against the
others, and there is no "wait for the top of the phrase".

## Settings from the dashboard

The **Settings** panel edits the config values that can change in a running rig. Each row
says when the change bites:

| | |
|---|---|
| `now` | pushed straight to the running synths |
| `beat` | read on the next beat |
| `record` | read when you next hit record — so re-record to hear it |

Edits change the **session only**. `Save to config.scd` writes them into the file, and it
is line-surgical: only the number on each assignment line is replaced, so every comment,
ladder and measurement in that file survives untouched. The previous version is kept as
`config.scd.bak`. `Reload from file` throws away unsaved changes and re-reads the file.

The rig's *shape* — audio device, sample rate, channel counts, the track layout — has no
slider, because changing it rebuilds synths or restarts the server. Those live in the
**Audio interface** and **Tracks** panels of the Setup view (below), and the same Save
button writes them back: `~audioDevice`, `~inDevice`, `~outDevice`, `~sampleRate`,
`~numInputs`, `~numOutputs`, `~trackInputs` and `~trackNames` are rewritten in place like
the numbers are. `~minCps`, `~maxLoopCycles` and the ports remain editor-only.

## Audio interfaces

The dashboard's **Setup** view lists every audio device on the machine with its input and
output counts, and moves the rig onto one. Click a device to use it for both directions
(what an ASIO driver requires); shift-click / alt-click picks it for input or output only,
which the other Windows driver classes (WASAPI, MME, DirectSound, WDM-KS) need, since they
expose inputs and outputs as separate endpoints. Then **Apply**.

Two facts shape how this works:

- **The channel counts come from `scsynth`, not sclang.** `ServerOptions.devices` returns
  names only. The one thing that knows how many channels a device has is the server,
  which prints the whole table every time it boots — so the scan launches a throwaway
  `scsynth` on a spare port (`~scanPort`) with a sample rate no device accepts (`-S 1`):
  it enumerates everything, fails to open a stream, and exits on its own in under a
  second. The running server never notices, and the click keeps ticking (the launch is
  non-blocking).
- **Switching is a server restart.** Device, rate and channel counts are server options,
  read once at boot; there is no "change device" message. So Apply quits the server,
  sets the options and boots again through the same `~bootAll` as the first boot of the
  day. Everything that survives `Ctrl+.` survives this too — the `ServerQuit` hooks
  forget SuperDirt and the buffers, the `ServerTree` hooks rebuild. **Loops do not
  survive** (buffers die with the server); the **track layout does**. The page asks
  before restarting if anything is playing, and shows a banner until the rig is back.
  If scsynth crashes on the way out — it sometimes does on Windows while closing an
  MME/WASAPI stream, and then never answers `/quit` — a watchdog notices the process is
  gone and boots anyway, a few seconds later.

A rig whose configured interface is unplugged no longer just fails in the post window:
the dashboard comes up anyway (the device, settings and dashboard modules load *before*
the boot), reports `device not found`, and lets you pick what *is* there. From the
editor: `~scanDevices.();` then `~useDevice.("ASIO : ZOOM H8 Audio Driver");`.

Asking for more input channels than a device has is safe — scsynth boots and the extra
channels are silent — so a layout written for the H8's 12 inputs still builds on a 2-in
laptop mic. Each such track gets a warning in the post window and reads "not on this
device" in the Setup menus until it is re-wired.

## Tracks from the dashboard

A session starts with **zero tracks**. The **Tracks** panel in Setup is where the layout
is built: name, **source**, a live input meter so you can *see* what you plugged into, and
Remove. **Add track** appends — never inserts — so existing strips keep their numbers.

A source is a hardware jack (one, or a pair for stereo) **or a VST instrument**, picked
from the same menu — instruments appear there as `♪ piano`. That is the whole of "looping
a MIDI instrument": the track records the instrument's output, so you play a phrase on the
keyboard, it loops, and you keep playing over it.

- **Re-wiring a track to another jack keeps its loop.** The input is a control-rate bus
  number the synth reads, so the change is a `.set`, with no dropout — an overdub in
  progress simply continues on the new signal.
- **Changing the source's shape rebuilds the track and clears its loop** — mono ↔ stereo,
  or jack ↔ instrument — because BufRd/BufWr channel counts are fixed when the SynthDef is
  built. The page asks first if the track is playing.
- The cap is `~maxTracks` (12). Each track costs a looper + FX synth and one pre-allocated
  buffer — ~7 MB mono, ~14 MB stereo at the defaults — so the limit is the interface's
  input count and a strip list you can still navigate mid-set, not the machine.

From the editor: `~addTrack.(5, "bass");  ~addTrack.([0, 1], "mic");
~addTrack.("vst:piano", "keys");  ~setTrackInput.(2, 7);  ~renameTrack.(2, "synth");
~removeTrack.(2);`

### Looping a VST instrument

A track whose source is `vst:<name>` records that instrument's **own bus**, which has
three consequences worth knowing:

- **The recording is pre-fader.** Moving the instrument's level afterwards changes what
  you hear live, never what was recorded.
- **The track does not monitor.** You already hear the instrument through its own fader,
  so monitoring it on the track as well would play it twice — and adding a track would
  make the instrument jump in level for no visible reason. `~monLevel` skips these tracks.
- **Order of execution matters, and is handled.** scsynth zeroes every audio bus at the
  start of each control block, so a looper that runs *before* its instrument records
  silence — not late audio, silence. Instruments therefore live in `~srcGroup` and loopers
  in `~loopGroup`, which runs after it (FX stay at the tail). Without those groups this
  worked or didn't depending on whether the track or the instrument was added first.

An instrument that is not open yet — the plugin scan is async, and a saved layout can name
one that was removed — reads a dedicated **silent bus** rather than bus 0. Bus 0 is the
master output, so the obvious fallback would record the entire mix, including the track's
own playback: feedback on the first press of record. When the instrument opens, its tracks
are pointed at the real bus with a `.set`, so a loop already recorded keeps playing.

The layout lives in `~trackInputs` / `~trackNames` — the same variables `config.scd`
sets at boot — so it survives a reload of `looper.scd` and a device switch, and Save
writes it into the file. `Reload from file` rebuilds the tracks only if the file's layout
differs from the session's.

## VST instruments

SuperCollider cannot host plugins on its own; the **VSTPlugin** extension
(https://git.iem.at/pd/vstplugin) adds a UGen that runs a VST2/VST3 plugin inside scsynth's
audio thread and a controller in sclang for MIDI, parameters, presets and the plugin's
editor. It lives in `%LOCALAPPDATA%\SuperCollider\Extensions\VSTPlugin` (recompile the class
library after installing); plugins are found in the standard Windows VST folders plus
`~vstDirs` — Surge XT's portable build is in `D:\vst`. Without the extension the rig runs
as before, minus instruments.

An instrument is a name and a plugin: **Setup → Instruments → Add**, or
`~vstAdd.("surge", "Surge XT.vst3");`. Then, in Tidal:

```haskell
d1 $ n "0 4 7 <12 9>" # s "surge" # sustain 0.4
```

That goes through SuperDirt's own MIDI event type — `addMIDI` takes anything with a
`MIDIOut`-shaped API, and the plugin controller's `.midi` is exactly that — so the notes
are scheduled on SuperDirt's clock like everything else, and Tidal's MIDI params
(`midichan`, `ccn`/`ccv`, `nrpn`, `midibend`…) all work. **Editor** opens the plugin's own
window. Each instrument has a level and a meter, and its own stereo bus — which is what a
looper track records when you point it at the instrument (see *Looping a VST instrument*).

### MIDI keyboards

Every instrument picks its **own** keyboard, from a menu on its strip (Perform) or its row
(Setup): *no MIDI*, *any device*, or one of the devices found by the scan. So two
controllers can play two plugins at once, and adding a second instrument does not silently
double what you play — the first instrument added defaults to *any device*, the rest to
*none*. The channel is passed through unchanged.

**Plugged something in after booting?** Press **Rescan MIDI** in Setup (or
`~scanMidiSources.();`). It re-initialises the MIDI client, so a keyboard connected
mid-session is picked up without restarting anything.

The binding is stored as the device's **label**, not its uid: uids are handed out per
session and shuffle when you replug, so a saved uid would point at whatever happened to be
first tomorrow. A label that is not connected right now still shows in the menu marked
*(not connected)*, and simply receives nothing until the device is back — which is also
what tells you why an instrument is silent.

`Ctrl+.` frees every synth, and with it the plugin instance and whatever you dialled in.
So an instrument's program data is snapshotted every `~vstSnapshotSecs` (60 s) and put
back when the `ServerTree` hook rebuilds it; a device switch goes through the same path.
Those snapshots are also what a saved session will carry. `~vstInstruments` in
`config.scd` is the boot list, written by Save like the tracks.

### Playing a VST live: where the delay is

The keyboard path is deliberately the shortest one there is — MIDI in → sclang → an
untimestamped `/u_cmd` to the plugin → audio. Measured on this machine: **4.5–8 ms** from
note-on in sclang to sound on the instrument's bus. Everything else is the audio device:

| Device | PortAudio's own figure | Honours a buffer request? |
|---|---|---|
| ZOOM H8, ASIO | set by the buffer size (128 ≈ 3 ms at 44.1 k) | yes |
| laptop audio, WASAPI | 22 ms in / 23 ms out, plus the engine's 10 ms | **no** — shared mode |
| laptop audio, DirectSound | 121 ms out | no |
| laptop audio, MME | 100 ms+ | no |

So a "considerable" delay on the laptop's own audio is the laptop, not the rig. For live
playing use the H8 and set the **buffer size** in the device panel (`~hardwareBufferSize`,
saved with the device) as low as it runs clean — 128, then 64. Turning off the Realtek
"audio enhancements" in Windows sound settings helps the laptop case somewhat. Nothing here
is compensated: unlike a loop, a live instrument is heard directly, so the only strategy is
to make the path short. Tidal → VST is unaffected either way (scheduled on the grid).

## The dashboard: Perform and Setup

The page has two views. **Perform** is the stage screen: metronome, strips, mixer.
**Setup** is soundcheck: audio interface, tracks, settings, the controller legend and the
keyboard map, with a sticky Save bar. Keys `1` / `2` switch; the metronome, the gamepad
and the state stream keep running whichever is showing. A dot on the Setup tab means
something is unsaved.

Every strip carries an **input meter** (signal at the jack; red at clipping) and, once it
holds a loop, a **play head** along its bottom edge with a tick per bar — so you see the
bar line coming before you punch in. The play head costs no traffic: buffers are locked
to the phrase grid, so a 4-bar loop is at `(cycle mod 4) / 4` and the browser places it
from the clock reference it already has. The meters do cost traffic (`~meterRate`, 12/s),
and only flow while a *visible* dashboard keeps renewing a subscription every 2 s: close
or hide the tab and the synths go quiet within 5 s, so the idle-traffic guarantee holds.

**Keyboard**: `↑ ↓` select, `← →` level (shift = fine), `R` record, `O` overdub, `C`
clear, `space` stop/start on the bar, `P` pin, `K` click. Nothing fires while a text box
or menu has the cursor.

## The loop join

Where a loop wraps, two things can go wrong, and they are not the same problem:

| | Symptom | Knob |
|---|---|---|
| **Head** | a click at the seam | `~headFadeSecs` |
| **Tail** | a cymbal or ringing note cut dead | `~tailSecs` |

They want opposite things, which is why one number could not serve both.

**`~headFadeSecs`** (default 3 ms) is a fade-in on the loop start, there only to remove
the step that clicks. It has to stay well under an attack transient (10-50 ms) or a hit
on beat 1 is heard arriving soft — that is what "the join is too long" was. If there *is*
a hit on the 1 you can set it to `0`: a click coincident with a loud attack is masked and
inaudible anyway.

**`~headWindowSecs`** (default 30 ms) opens the take that much *before* the downbeat and
cuts the loop there instead. It moves the **seam**, not the audio — see below.

**`~tailSecs`** (default 0.5 s) keeps recording past the loop end, and plays that extra
audio back **added on top** of the loop start, decaying over its own length. It is not a
second copy of the start — `buf[frames]` is literally the sample after `buf[frames-1]`,
so the tail is the genuine continuation of the take. A crash rings on into the next
repetition exactly as it would if a drummer repeated the phrase.

Because the tail is a continuation rather than a duplicate, nothing has to sum to unity,
so there is no equal-power/equal-gain question left to get wrong. `~tailCurve` below 1
holds the tail near full early and preserves the natural shape of the decay.

### Why the head window exists

The buffer is a closed circle of exactly one phrase, and whatever sits *just before* the
cut was recorded at the **end** of the take — a different pass round the loop.

So if you strike the 1 slightly early and the cut sits on the 1, the strike's onset
belongs to one pass and its body to another. The loop replays a truncated attack: a crash
that starts halfway in, a snare with the crack shaved off. Cutting the circle 30 ms
earlier puts the whole strike on one side of it.

It also lands the seam somewhere quiet rather than on top of a transient, which is the
easiest place for a join to hide.

**It is not `~loopOffset`.** That moves the audio against the grid — turn it the wrong way
and everything sounds early or late. The head window moves the grid's *cut point* against
the audio, and the loop stays exactly one phrase long either way, so nothing drifts and
nothing shifts in time. The window is dead space the loop has to carry, so keep it near
the size of the rush you actually play.

> **The one catch:** a long tail only sounds right if what happens past the loop point is
> *decay*. Keep playing through it and the tail holds your performance of the next
> downbeat, landing on top of the recorded one — a real flam. Shorten `~tailSecs` on parts
> you play continuously.

All three are read when you hit **record**, so change them and re-record to hear it.
`~headFadeSecs = 0; ~tailSecs = 0;` is an exact bypass — a butt splice, verified.

## Click controls

Toggle with **OPTIONS** on the controller, the dashboard button, or `~clickOn = true;`
in the editor. Live tuning:

```supercollider
~clickDiv    = 4;      // clicks per cycle (4 = quarter notes)
~clickAmp    = 0.5;    // level
~clickOffset = 0.0;    // phase trim vs the music, seconds — nudge until it sits on the beat
```

The click is on the **right channel only**. Confirm your PA cable takes the **left**
channel (mono/TS) so the audience never gets the click.

## Hardware notes

- **ZOOM H8** — ASIO `ASIO : ZOOM H8 Audio Driver`, **must be 44100 Hz**.
  Only **2 physical outputs** (Line Out + Headphone share the same stereo mix), so
  there is no private monitor bus. Click hack: music mono-**LEFT**, click mono-**RIGHT**,
  feed the PA from Line Out with a **mono cable** (tip = left) so the audience gets the
  music without the click. (Fixed properly by a ≥4-out interface later.)
- **PS5 DualSense** (Bluetooth) — the control surface. It is read by the *browser's*
  Gamepad API in the dashboard, not by SuperCollider: on Windows, SC's HID layer cannot
  open a top-level collection on the Generic Desktop usage page, which is every gamepad.
  The dashboard window must stay **visible** — browsers throttle a hidden tab and the
  controller goes dead.

  | Control | Does |
  |---|---|
  | left stick ↑↓ / d-pad | move the focus — tracks, then the tidal & click levels |
  | left stick ←→ | volume of the focused item |
  | right stick ↑↓ | scroll the dashboard |
  | ✕ Cross | **pin / unpin** the focused track |
  | ○ Circle | **record** — a fresh take on every selected track |
  | □ Square | **overdub** — layer onto them / stop layering |
  | △ Triangle | **clear** — stop and clear them |
  | touchpad | **stop / start** the loop, on the next bar |
  | R2 | drive on the focused track — pressure = amount |
  | OPTIONS | click on / off |

  Record and overdub are separate on purpose: record punches straight over a playing loop
  without clearing first, which a single cycling button can't do. Overdub on an empty
  track does nothing rather than quietly becoming a recording.

  Clicking a strip in the dashboard selects it too, so the mouse is a full alternative.

  There is **no MIDI control surface**. An AKAI MPK mini map used to exist and was
  removed: two surfaces that can disagree about which track is selected is worse than
  one. `git show 10cc44d:looper.scd` has it if you ever want it back.

- **SPD-SX PRO** — an instrument only. Its audio goes into the H8 like any other source;
  nothing in the rig reads MIDI at all.

## Troubleshooting

**Port 57120 stuck after a crash** (PowerShell):

```powershell
(netstat -ano | Select-String ":57120 ") -replace '.*\s(\d+)$','$1' | Select-Object -Unique | ForEach-Object { Stop-Process -Id ([int]$_) -Force -ErrorAction SilentlyContinue }
Get-Process scsynth, sclang -ErrorAction SilentlyContinue | Stop-Process -Force
```

Then recompile SC (Ctrl+Shift+L) before booting again.

**Changed audio device** → recompile class library first (Ctrl+Shift+L).
