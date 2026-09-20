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
// Don't know the string? The dashboard's Setup view scans and lists every device with
// its input/output counts (or in the editor:  ~scanDevices.();  then  ~devices).
//
// ~audioDevice is used for BOTH input and output — the normal case, and the only one an
// ASIO driver allows. Windows' other driver classes (WASAPI, MME, DirectSound, WDM-KS)
// expose input-only and output-only endpoints, so to record through one device and play
// through another set ~audioDevice = nil and name the two halves separately.
// All of these are what the dashboard writes when you pick a device and press Save.
~audioDevice = nil;
~inDevice    = "Windows WASAPI : Varios micrófonos (Intel® Smart Sound Technology for Digital Microphones)";          // only read when ~audioDevice is nil
~outDevice   = "Windows WASAPI : Altavoces (Realtek(R) Audio)";          // only read when ~audioDevice is nil
~sampleRate  = 44100;        // H8 ASIO requires 44100. nil = whatever the device prefers
~numInputs   = 1;           // raise if a jack maps past index 11 (tools/input-scan.scd).
                             // Asking for MORE inputs than the device has is safe — the
                             // extra channels are simply silent — so the scan's count is
                             // a floor, not a ceiling.
~numOutputs  = 2;            // H8 has only 2 physical outs (L = music, R = click hack)
// Hardware buffer, in samples: THE latency knob for anything played live — a MIDI
// keyboard into a VST, the guitar monitored through SC. nil = the driver's own setting.
// ASIO honours it (the H8: 128 ≈ 3 ms at 44100, try 64 if it stays clean); Windows'
// shared-mode drivers (WASAPI, MME, DirectSound) ignore it — the laptop's built-in audio
// is ~23 ms out whatever you ask. Dropouts = too small for this machine, go up a step.
~hardwareBufferSize = nil;
~scanPort    = 57199;        // spare UDP port for the throwaway scsynth the device scan runs
~numBuffers  = 1024 * 16;
~memSize     = 8192 * 16;    // server real-time memory, KB


// ── Tidal / SuperDirt ───────────────────────────────────────
~dirtPort   = 57120;         // where Tidal sends its OSC
~dirtOrbits = 8;             // d1..d8. Every orbit runs its own always-on effect chain,
                             // so drop this to 4 if you never reach for d5..d8.

// Which Dirt-Samples banks to load at boot.
//   nil  = the whole library: 219 banks, ~450 MB, ~30 s off every boot — and off every
//          device switch, since that is a boot too.
//   list = only these. One bank is a fraction of a second.
// Your samples/ folder is loaded on top either way.
// Left one out mid-set? No restart needed:   ~loadBanks.([\tabla, \arpy]);
// See what's actually loaded:                ~dirt.postSampleInfo;
//
// Just one bank for now, as an example (24 kicks:  d1 $ s "bd*4"). Add to the list as
// the set grows, or set nil to get everything back.
~sampleBanks = [\bd];
// A fuller starting point when you want it:
// ~sampleBanks = [\bd, \sd, \sn, \hh, \hc, \cp, \rm, \jungle, \arpy, \tabla];


// ── VST instruments ─────────────────────────────────────────
// Needs the VSTPlugin extension (in %LOCALAPPDATA%\SuperCollider\Extensions). Without it
// the rig runs fine, just without instruments — vst.scd says so at boot.
//
// Folders to scan for plugins, on top of the standard Windows VST2/VST3 locations. The
// scan is cached by VSTPlugin, so a boot costs a fraction of a second once it has run.
~vstDirs = ["D:/vst"];
// Instruments the rig boots with, as [name, plugin, midi] triples:
//   name    what Tidal plays it as (`# s "surge"`) and what the dashboard shows.
//           Letters, digits and _ only — it is a Tidal sound name.
//   plugin  the key the scan gives it, e.g. "Surge XT.vst3".
//   midi    which keyboard plays it: "" none, "*" any device, or the device's label
//           ("CASIO USB-MIDI"). A LABEL, not a uid — uids are handed out per session and
//           change when you replug, so a saved uid would point at the wrong thing.
// Added from the dashboard's Setup view; Save writes them here like the tracks. A
// session starts with none unless listed.
//     ~vstInstruments = [["surge", "Surge XT.vst3", "CASIO USB-MIDI"]];
~vstInstruments = [];
~maxVsts        = 8;         // each one is a plugin instance; Surge XT is light, a big
                             // sampler is not — the machine's RAM is the real limit
// Read hardware MIDI at all. Each instrument picks its own keyboard from what the scan
// finds (dashboard → Rescan MIDI after plugging one in), so two controllers can play two
// plugins at once. The channel is passed through unchanged.
~vstMidiIn      = true;
// Plugin state is snapshotted this often so it survives Ctrl+. (which frees the plugin
// instance). 0 disables. Session saving will reuse these snapshots.
~vstSnapshotSecs = 60;


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
//
// A session STARTS EMPTY: tracks are added from the dashboard's Setup view (or
// ~addTrack.() in the editor), each on the jack you choose, with a live meter to confirm
// it. Whatever is listed here is only what the rig boots with — a layout you have pressed
// Save on. Leave both empty to always start from nothing. (Saving a whole session —
// layout plus levels, lengths and so on — is planned separately.)
//
// The H8 layout that used to live here, for reference:
//     ~trackInputs = [[0, 1], 5, 9, 7, 8, 4, 6];
//     ~trackNames  = ["mic", "bass", "synth", "voice", "spdsx", "bomboclat", "overhead"];
~trackInputs   = [];

// Display names, in the same order. Shown on the dashboard strips and in the post
// window. tools/input-scan.scd prints this line alongside ~trackInputs so the two
// cannot drift apart. A missing name falls back to "Track N".
~trackNames    = [];

// Ceiling on tracks the dashboard will let you add. Each one costs a looper + FX synth
// (cheap) and a pre-allocated buffer: at the defaults below that is ~7 MB mono, ~14 MB
// stereo. Twelve stereo tracks is ~170 MB, fine on this 8 GB machine; the practical
// limit is the interface's input count and a strip list you can still navigate with a
// stick mid-set.
~maxTracks     = 12;

// Default length of a NEW loop, in bars (one Tidal cycle = one bar at ~clickDiv 4).
// Each track keeps its own length, so a 4-bar part can sit under an 8-bar one — they
// still stack, because each locks to its own phrase grid and 4 divides 8.
~numLoopCycles    = 4;
~loopCycleChoices = [4, 8];  // what the length control steps through
~maxLoopCycles    = 8;       // buffers are sized for THIS, so it must cover the choices

// ── Loop join: head fade + tail ─────────────────────────────
// Two different problems, so two different knobs. They used to be one (~xfadeSecs) and
// no single value could be right for both.
//
// HEAD FADE — a few milliseconds at the loop start, there only to remove the step that
// makes the seam click. Keep it well under an attack transient (10-50 ms) or a hit on
// beat 1 is heard arriving soft: that is what "the join is too long" was.
//     0        no fade. Fine when there IS a hit on the 1 — a click coincident with a
//              loud attack is masked and you cannot hear it anyway.
//     0.002 - 0.005   de-clicks a quiet seam, inaudible on a loud one      <- set here
//     0.02  +         you are now softening attacks
~headFadeSecs = 0.003;

// HEAD WINDOW — how far BEFORE the downbeat the take opens, and the loop is cut.
// This is not the fade and it is not ~loopOffset. Those move the audio; this moves the
// SEAM, leaving the audio exactly where you played it.
//
// The buffer is a closed circle of exactly one phrase. Whatever sits just before the cut
// was recorded at the END of the take — a different pass round the loop. So if you strike
// the 1 a little early and the cut sits ON the 1, the strike's onset belongs to one pass
// and its body to another, and the loop replays a truncated attack: a crash that starts
// halfway in, a snare with the crack shaved off it.
//
// Cutting the circle a few tens of milliseconds earlier puts the whole strike on one side
// of it. As a bonus the seam lands somewhere quiet instead of on top of a transient,
// which is the easiest place for a join to hide.
//     0        cut exactly on the downbeat
//     0.02 - 0.05     covers a normal human rush on the 1                  <- set here
//     0.08 +          only if you play very far ahead; the window is dead
//                     space the loop has to carry
// Capped at a quarter of the loop, and read when you hit RECORD.
~headWindowSecs = 0.05;

// TAIL — recording keeps running past the loop end by this much, and that extra audio is
// played back ADDED on top of the loop start, decaying away over its own length. This is
// what carries a cymbal or a ringing note across the seam instead of cutting it dead.
//
// It is not a second copy of the loop start: buf[frames] is literally the sample after
// buf[frames-1], so the tail is the genuine continuation of the take. That is also why
// there is no equal-power/equal-gain question here any more — the head plays at full
// gain and the tail is a ghost on top, so nothing has to sum to unity.
//     0        off, a butt splice
//     0.1 - 0.3       covers a snare ring or a short room tail
//     0.4 - 0.8       covers a crash or a big reverb                       <- set here
//     1.5 +           only if you are recording something genuinely long
//
// THE ONE CATCH: this only sounds right if what happens past the loop point is DECAY.
// Play new notes through the loop point and the tail holds your performance of the next
// downbeat, landing on top of the recorded one — a real flam. The fade-out softens it,
// and per-track lengths are the escape hatch: long on overheads, short on a part you
// play continuously.
~tailSecs  = 0.18;
// Tail decay shape. Below 1 holds the tail near full early and preserves the natural
// shape of the decay; 1 is a straight line; above 1 drops it away quickly.
~tailCurve = 0.45;

// Buffers are sized for ~tailSecs on top of the longest loop, and a take caps the tail
// at a quarter of the buffer so a long tail can never eat the loop itself.
//
// All four are read when you hit RECORD, not continuously: change them, then re-record.

// Which cycle boundaries a recording is allowed to START on. 1 = the next measure, which
// is almost always what you want when you hit record.
// This does NOT affect whether loops line up with each other: the buffer is locked to the
// phrase grid, so a loop armed halfway through a phrase still records into the right part
// of the bar. Raise it only if you want punch-in itself to be coarser.
~recordQuantize = 1;
// Compensates the audio round trip, in seconds. THIS IS A WORKING KNOB — an earlier
// comment here said it was a no-op, which was true before loop buffers were locked to the
// phrase grid and is not true now. Measured: 0.1 here shifts the recording 96 ms against
// the grid.
//
// You play in time with what you HEAR, so your playing reaches the converter late by the
// input latency and comes back late again by the output latency — the full round trip.
// The loop therefore sits that far late against the patterns, and this shifts the write
// position back to cancel it. Too far and the loop sounds early: that is the other side
// of the same adjustment, not a different problem.
//
// MEASURED on this H8 with tools/latency-measure.scd: 28.9 ms round trip, 0.1 ms spread
// over five pings. Independently, 0.025 had been arrived at by ear — the two agree.
// Re-measure after any change to the buffer size, the sample rate or the interface:
//     "D:/livelooper/tools/latency-measure.scd".load;  ~measureLatency.(1);
~loopOffset    = 0.025;

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


// ── Effects ─────────────────────────────────────────────────
// Every track runs through its own FX synth. At drive 0 it is a true bypass (the dry
// signal is crossfaded through untouched), so leaving it in costs nothing audible.
//
// The drive is voiced for GUITAR: lows are rolled off before the clipping stage, the way
// an amp does, because clipping a full-range low string just sounds muddy. Raise
// ~fxPreHighpass for an even tighter, more aggressive break-up; lower it toward 60 for
// bass, where you want the fundamental to survive.
~fxPreHighpass = 120;        // Hz, before the clipper
~fxTone        = 0.5;        // post-clip brightness, 0 = dark .. 1 = fizzy
~fxDriveMax    = 1.0;        // how far the R2 trigger can push the drive (0..1)



// ── Click ───────────────────────────────────────────────────
~clickDiv    = 4;            // clicks per cycle (4 = quarter notes in 4/4)
~clickAmp    = 0.5;
// Phase trim of the CLICK against the music, in seconds. Read live on every beat, so you
// can tweak it in the interpreter and hear it immediately — then write the value back.
// 0 is correct by construction: the beat grid is anchored to when events SOUND, and the
// click hands the server its own lead, so there is no systematic error left to cancel.
//
// DO NOT use this to compensate the round trip — that is ~loopOffset's job, and they are
// not interchangeable. Pulling the click early WOULD make you play early enough to land
// on the grid, but it moves something you HEAR: the click would then be ~29 ms out of
// time with the Tidal patterns, which is a flam you would be playing against all night.
// ~loopOffset fixes the same error by moving the RECORDING, which nobody hears happen.
// Splitting the correction between the two only buys half of that flam for nothing.
//
// Keep the two questions separate, or neither can be tuned:
//     ~clickOffset — is the click in time with the patterns?
//     ~loopOffset  — is my recording in time with what I heard?
~clickOffset = 0.0;


// ── Dashboard ───────────────────────────────────────────────
~dashPort = 57130;           // the Node bridge listens here for state from SC.
                             // The browser's HTTP port is set in dashboard/server.js.
// Per-track input/output level meters, in updates per second. They only flow while a
// dashboard is open and visible (the browser keeps a subscription alive), so a closed
// dashboard costs nothing and the idle-traffic guarantee still holds. 0 disables them.
~meterRate = 12;

"config.scd loaded.".postln;
