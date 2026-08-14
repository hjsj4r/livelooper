// ============================================================
//  LIVE LOOPER · config.scd
//
//  Everything you change for a different rig, room or set lives here. Moving to new
//  hardware should not require editing any other file.
//
//  Loaded first by startup.scd; looper/click/dashboard read these values.
//  These are SETUP values. Things you toggle mid-performance (click on/off, focused
//  track, fader positions) are runtime state and are deliberately not here.
// ============================================================


// ── Audio interface ─────────────────────────────────────────
// Exact device name as SuperCollider sees it; nil = system default.
// Don't know the string?   ServerOptions.devices.do(_.postln);
~audioDevice = "ASIO : ZOOM H8 Audio Driver";
~sampleRate  = 44100;        // H8 ASIO requires 44100
~numInputs   = 12;           // raise if a jack maps past index 11 (tools/input-scan.scd)
~numOutputs  = 2;            // H8 has only 2 physical outs (L = music, R = click hack)
~numBuffers  = 1024 * 16;
~memSize     = 8192 * 16;    // server real-time memory, KB


// ── Tidal / SuperDirt ───────────────────────────────────────
~dirtPort   = 57120;         // where Tidal sends its OSC
~dirtOrbits = 8;             // d1..d8. Every orbit runs its own always-on effect chain,
                             // so drop this to 4 if you never reach for d5..d8.

// Which Dirt-Samples banks to load at boot.
//   nil  = the whole library: 219 banks, ~450 MB, ~14 s off every boot.
//   list = only these. Three banks is about 5 MB — an 88x cut, and near-instant.
// Your samples/ folder is loaded on top either way.
// Left one out mid-set? No restart needed:   ~loadBanks.([\tabla, \arpy]);
// See what's actually loaded:                ~dirt.postSampleInfo;
~sampleBanks = nil;
// Uncomment and edit once you know what your set uses:
// ~sampleBanks = [\bd, \sd, \sn, \hh, \hc, \cp, \rm, \jungle, \arpy, \tabla];


// ── Loopers ─────────────────────────────────────────────────
// One entry per track. Order = track order and dashboard strip order, so APPEND when
// adding — inserting renumbers tracks and moves the selection under your fingers.
//
//   5        a mono jack on SC input 5
//   [0, 1]   a STEREO pair — one track fed by two inputs, e.g. a stereo mic.
//            The pair does not have to be adjacent.
//
// The H8's ASIO channel order is NOT a simple sequence, so never assume it: map every
// jack with tools/input-scan.scd (tap each one, then ~inputSummary.()).
// Verified so far on this H8:
//     SC 5 = H8 input 2
//     SC 8 = H8 "Input A"        (earlier note; re-scan if it ever misbehaves)
//     SC 9 = extra instrument
//
// Mapped with tools/input-scan.scd. SC 10 and 11 carry the H8's MIX (they light up for
// every source), so they are deliberately not tracks — 2 and 3 were unused.
~trackInputs   = [[0, 1], 5, 9, 7, 8, 4, 6];

// Display names, in the same order. Shown on the dashboard strips and in the post
// window. tools/input-scan.scd prints this line alongside ~trackInputs so the two
// cannot drift apart. A missing name falls back to "Track N".
~trackNames    = ["mic", "bass", "synth", "voice", "spdsx", "bomboclat", "overhead"];

~numLoopCycles = 4;          // record length, in Tidal cycles

// Which cycle boundaries a recording is allowed to START on. 1 = the next measure, which
// is almost always what you want when you hit record.
// This does NOT affect whether loops line up with each other: the buffer is locked to the
// phrase grid, so a loop armed halfway through a phrase still records into the right part
// of the bar. Raise it only if you want punch-in itself to be coarser.
~recordQuantize = 1;
// Shifts where a loop's BOUNDARY falls in the bar. It does NOT correct loop timing:
// record and play share one Phasor, so moving the start moves both and the shift
// cancels. A loop's real error is the interface round trip. Leave at 0.
~loopOffset    = 0.0;

// Loop buffers are allocated ONCE, at the size the slowest tempo you'll ever record at
// needs — so hitting record never allocates and never stalls. Lower = longer buffers =
// more RAM. Recording slower than this still works but the loop is truncated, and the
// post window says so.  Cost: numLoopCycles / minCps seconds, mono, per track.
//   0.2 cps with 4 cycles = 20 s = ~3.5 MB per track.
~minCps        = 0.2;
~monLevel      = 1.0;        // live input monitored through SC. Set to 0 if you monitor
                             // direct on the H8 — that removes the A/D→D/A round trip
                             // from what you hear while playing.
~restoreLoopsOnPanic = true; // Ctrl+. re-arms playing loops instead of dropping them


// ── MIDI control surface (AKAI MPK mini) ────────────────────
// The MPK drives the loopers and sends on channel 0. The SPD-SX PRO sends on channel 9,
// so with ~midiChan = 0 it is inert here and stays purely an instrument.
~midiChan = 0;

// Captured with tools/midi-monitor.scd — re-run it if you move the MPK's PAD BANK
// button, because the pads send different notes per bank.
//   bank A = notes 16..23      bank B = notes 32..39 (fixed velocity 127)
//
// These three act on the SELECTED track (~focus), so they scale to any number of tracks.
// Record and overdub are separate on purpose: record punches a fresh take over a playing
// loop without clearing it first, which a single cycling button cannot do.
~padRecord  = 36;            // pad 5 — start a fresh take on the selected track
~padOverdub = 37;            // pad 6 — layer onto it / stop layering
~padClear   = 38;            // pad 7 — stop and clear it

// Track level, one knob per track, in track order. The MPK's 8 knobs are CC 48, 49, 50,
// 51, 64, 65, 66, 67 — assumed to run left-to-right in that order. If a knob moves the
// wrong track, check the real order with tools/midi-monitor.scd and reorder this list.
~knobFader = [48, 49, 50, 51, 64, 65, 66];

// Toggles the click. nil = no MIDI control (use the dashboard button, or ~clickOn).
// Only ever put a PAD number here: on channel 0 the MPK's KEYBOARD sends notes too, and
// a keyboard note used as a control would fire every time you play it. Pads 35 and 39
// are unassigned above if you want one.
~clickPedal = nil;
~midiDebug  = false;         // true = post every MIDI message. Use it to discover pedal
                             // numbers; leave it off for a show (posting on every pad
                             // hit stalls the IDE).


// ── Click ───────────────────────────────────────────────────
~clickDiv    = 4;            // clicks per cycle (4 = quarter notes in 4/4)
~clickAmp    = 0.5;
// Phase trim vs the music, in seconds. Read live on every beat, so you can tweak it in
// the interpreter and hear it immediately — then write the value back here.
// 0 is now correct by construction: the beat grid is anchored to when events SOUND, and
// the click hands the server its own lead, so there is no systematic error left to
// cancel. Treat any non-zero value as taste (or as a sign something else is off).
~clickOffset = 0.0;


// ── Dashboard ───────────────────────────────────────────────
~dashPort = 57130;           // the Node bridge listens here for state from SC.
                             // The browser's HTTP port is set in dashboard/server.js.

"config.scd loaded.".postln;
