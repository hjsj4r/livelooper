# Live Looper — TidalCycles + SuperCollider

Music coding + live guitar looping, tightly synced. **TidalCycles** generates the
patterns; **SuperCollider** runs SuperDirt (drums/samples), the guitar loopers, and a
tempo-locked click. A **Roland SPD-SX PRO** drives the loopers hands-free.

> Migrated off Strudel — no browser, no `node server.js` OSC bridge. Tidal sends OSC
> to SuperDirt directly over UDP.

## Architecture

```
TidalCycles (Haskell, code)  ──OSC──►  SuperCollider
                                         ├─ SuperDirt   (drums / samples)
                                         ├─ Loopers     (guitar, cycle-synced)
                                         ├─ Click       (panned RIGHT — L/R hack)
                                         └─ MIDI in     (SPD-SX PRO pedals)
                                       → ZOOM H8:  L = music → PA (mono cable)
                                                   R = click → your headphones
```

## Requirements

- SuperCollider 3.13+ — installed
- SuperDirt quark — installed
- ZOOM H8 as ASIO device @ 44100 Hz
- TidalCycles + VS Code `vscode-tidalcycles` — **installed in step 6 (not yet)**

## Daily startup

1. Open **SuperCollider**, open `startup.scd`.
2. Click inside the parens and press **Ctrl+Enter** — one evaluation does everything.
   Wait for `=== LIVE LOOPER READY ===`.
3. VS Code → `Tidal: Boot`.
4. *(optional)* Dashboard: in a terminal, `cd dashboard` then `node server.js`, and open
   **http://localhost:3000**. No `npm install` needed.

Re-evaluating step 2 is safe and fast: it reloads the code without re-scanning the sample
library and without interrupting audio. Use it to apply an edit mid-session.

Quick audio check:

```supercollider
{ SinOsc.ar(440) * 0.1 ! 2 }.play;   // 440 Hz tone — Ctrl+. to stop
```

## Configuration

**Everything you'd change for a different rig lives in `config.scd`** — audio device,
sample rate, channel counts, track inputs, MIDI channel and pedal notes, click tuning,
ports. No other file should need editing to move to new hardware.

The project folder path is derived from `startup.scd`'s own location, so you can move or
clone the folder anywhere.

| Change | Then |
|---|---|
| Track inputs, pedals, click, loop length | re-evaluate `startup.scd` |
| Audio device, sample rate, channel counts | `s.reboot;` then re-evaluate `startup.scd` |
| Added a sample bank to `samples/` | `~reloadSamples.();` |
| Need a Dirt-Samples bank you trimmed out | `~loadBanks.([\tabla]);` — no restart |

Boot loads the **whole** Dirt-Samples library by default: 219 banks, ~450 MB, ~14 s every
time. Once you know what a set actually uses, list those banks in `~sampleBanks` — three
banks is about 5 MB and loads instantly. `~dirt.postSampleInfo;` shows what's loaded.

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
| `config.scd`   | **All settings** — device, tracks, pedals, click, ports |
| `startup.scd`  | One-evaluation boot: server + SuperDirt + everything else |
| `looper.scd`   | Multitrack loopers (one per input) + faders + MIDI |
| `click.scd`    | Tempo-locked click, right channel, pedal-toggle |
| `dashboard.scd`| Streams state to / takes commands from the web dashboard |
| `dashboard/server.js` | Pure-Node bridge (SC ↔ browser). Run: `node server.js` |
| `dashboard/index.html`| The web dashboard UI |
| `BootTidal.hs` | Tidal boot (SuperDirt target, tuned latency) |
| `samples/`     | Your custom sample banks |
| `tools/input-scan.scd` | Maps a physical jack to its SC input index |
| `tools/midi-monitor.scd` | Shows what a controller sends, per device, with a summary table |
| `tools/sync-check.scd` | Diagnoses loop timing / tempo mismatches |
| `tools/click-calibrate.scd` | Verifies the beat-grid anchor; `~clickOffset` should be 0 |
| `tools/loop-inspect.scd` | Reads a recorded loop back and finds holes in it |
| `test/midi-test.scd` | Regression test for the MIDI control surface |
| `test/panic-test.scd`  | Regression test for Ctrl+. recovery (see below) |
| `test/looper-test.scd` | Regression test for the record path + signal path |
| `test/dashboard-test.scd` | Regression test for the dashboard message rate |

## Roadmap

- [x] **1. Scaffold + consolidated `startup.scd`** (boot + SuperDirt + samples)
- [x] **2. Looper in `looper.scd`** + clear-during-record fix (generation token)
- [x] **3. Click in `click.scd`** — tempo-locked, right channel, pedal-toggle
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
- [x] **4. UI dashboard** — metronome, sample browser + preview, and **multitrack strips**
        (per-track record/overdub/clear + fader, click a track name to focus it for the pedals).
        Tracks configured in `looper.scd` via `~trackInputs`. Optional next: per-track waveforms.

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
that means one panic stop ends the set: no pedals, no click, no dashboard, no loopers,
and Tidal silent for good (SuperDirt rebuilds its orbits, but they feed a bus whose
master fader is gone).

The rig now registers everything it needs to come back:

| Mechanism | Brings back |
|---|---|
| `.fix` on every responder | pedals, tempo tracking, dashboard commands |
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
& $sc -D d:/livelooper/test/panic-test.scd       # 25 passed
& $sc -D d:/livelooper/test/looper-test.scd      # 29 passed
& $sc -D d:/livelooper/test/dashboard-test.scd   # 17 passed
& $sc -D d:/livelooper/test/midi-test.scd        # 17 passed
```

None of them needs the H8, and **they're safe to run while your rig is booted** — each
uses its own server port and builds SuperDirt without its sample library, so they take
seconds rather than minutes.

> Note: re-evaluating `looper.scd` **does** clear the loops (buffers are freed to avoid
> leaking them). Reloading a file is an authoring action; `Ctrl+.` is the live one.

MIDI message logging is now off by default — with permanent responders it would post on
every pad hit all night and stall the IDE. Turn it on to discover pedal note numbers:

```supercollider
~midiDebug = true;
```

## Click controls

Toggle with **pedal 62** (or `~clickOn = true;` in the editor). Live tuning:

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
- **AKAI MPK mini** — the looper control surface, MIDI channel 0. One pad per track,
  no "focused track" mode:

  | Control | Number | Does |
  |---|---|---|
  | pads (top row) | 36, 37, 38 | record → overdub → play, tracks 0/1/2 |
  | pads (bottom row) | 32, 33, 34 | clear, tracks 0/1/2 |
  | knobs | CC 64, 65, 66 | track level, tracks 0/1/2 |

  Pad notes **change with the PAD BANK button** (A = 16–23, B = 32–39). Stay on the bank
  you mapped, or re-run `tools/midi-monitor.scd` and update `config.scd`.

  The MPK's **keyboard shares channel 0**, so only ever map pad numbers — a keyboard note
  used as a control fires every time you play that key.

- **SPD-SX PRO** — MIDI channel 9, so it is inert as far as the loopers are concerned and
  stays purely an instrument.

## Troubleshooting

**Port 57120 stuck after a crash** (PowerShell):

```powershell
(netstat -ano | Select-String ":57120 ") -replace '.*\s(\d+)$','$1' | Select-Object -Unique | ForEach-Object { Stop-Process -Id ([int]$_) -Force -ErrorAction SilentlyContinue }
Get-Process scsynth, sclang -ErrorAction SilentlyContinue | Stop-Process -Force
```

Then recompile SC (Ctrl+Shift+L) before booting again.

**Changed audio device** → recompile class library first (Ctrl+Shift+L).
