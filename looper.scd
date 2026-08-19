// ============================================================
//  LIVE LOOPER  ·  looper.scd   (multitrack)
//  Loaded by startup.scd (REGION 2).
//  One independent loop per H8 input: record / overdub / clear + a fader each.
//  Controlled from the dashboard; the SPD pedals drive the FOCUSED track.
// ============================================================

// ── Settings come from config.scd ───────────────────────────
// (~trackInputs, ~numLoopCycles, ~loopOffset, ~monLevel, ~restoreLoopsOnPanic,
//  ~midiChan, ~mainPedal, ~clearPedal, ~midiDebug)
~trackInputs ?? {
    Error("looper.scd: config.scd has not been loaded. Evaluate startup.scd instead.").throw
};

// ── Runtime state (not config — survives a reload) ──────────
~cps   = ~cps ? 0.5;    // cycles/sec — updated live from Tidal OSC
~focus = ~focus ? 0;    // the SELECTED track — what the transport buttons act on

// ── Track tempo + cycle from every pattern event ────────────
// This runs on EVERY event Tidal sends — dense patterns across several orbits are easily
// 50-100/second — so it has to be cheap.
//
// SuperDirt already parses the OSC message into an Event and offers a hook for it
// (`var <>receiveAction`, called at SuperDirt.sc:316 just before the event is played).
// Reading that costs two dictionary lookups. The previous version ran its own second
// OSCdef on /dirt/play and scanned the raw message twice with `x.asString == "cps"`,
// allocating a String per element per scan — thousands of throwaway allocations a second
// to re-derive something SuperDirt had already computed.
//
// receiveAction is a plain instance variable, not a responder, so Ctrl+. leaves it
// alone (and SuperDirt .fix'es the OSCFunc that calls it).
~dirt ?? {
    Error("looper.scd: SuperDirt is not running. Evaluate startup.scd instead.").throw
};
// The anchor is ev[\timeStamp] — when the event SOUNDS — not Main.elapsedTime, which is
// merely when we heard about it. Tidal sends each event ahead of time (~220 ms on this
// rig) and sclang hands it over immediately, so anchoring to arrival put the whole beat
// grid that far early: recording opened before the downbeat, caught silence at the head,
// and clipped the same amount off the tail. That showed up as a hole exactly at the
// punch-in point — see tools/loop-inspect.scd.
~dirt.receiveAction = { |ev|
    ev[\cps]   !? { |c| ~cps = c };
    ev[\cycle] !? { |c|
        ~lastCycle     = c;
        ~lastEventTime = ev[\timeStamp] ? Main.elapsedTime;
    };
};

// Where Tidal's cycle counter is right now, extrapolated from the last event we saw.
~nowCycle = {
    (~lastCycle ?? { 0 })
        + ((Main.elapsedTime - (~lastEventTime ?? { Main.elapsedTime })) * (~cps ? 0.5))
};

// ── SynthDef (one instance per track) ───────────────────────
// inChan is ir (init-rate) — the H8 input is locked at Synth creation.
// ONE Phasor drives both read (BufRd) and write (BufWr): the record head can never
// drift from the play head, so overdub layers in place with no reset. reset snaps the
// phase to 0 to align the loop start to the grid. level = the track's mixer fader.
// Two defs, because BufRd/BufWr channel counts are fixed when the SynthDef is built.
// A mono jack gets \looperMono; a stereo pair (a stereo mic on two H8 inputs) gets
// \looperStereo. The two channels are separate ir controls rather than chan/chan+1, so
// a pair does not have to be adjacent — the H8's ASIO order is not a sequence.
SynthDef(\looperMono, { |bufnum, recLevel = 0, preLevel = 1, monLevel = 1.0,
        recRun = 0, playing = 0, reset = 0, level = 1.0|
    var inChan = \inChan.ir(0);
    // Loop length is a CONTROL, not the buffer's size. The buffer is allocated once at
    // its maximum length and Phasor just wraps earlier, so changing the loop length —
    // i.e. hitting record at a new tempo — costs one .set instead of a fresh multi-MB
    // allocation and a server round trip.
    var frames = \loopFrames.kr(44100);
    var dry    = SoundIn.ar(inChan);
    // resetPos locks the buffer to the PHRASE grid: position 0 always means "a cycle
    // that is a multiple of ~numLoopCycles". Punch in halfway through a phrase and the
    // reset jumps to the matching point in the buffer instead of to 0, so recording can
    // start on the very next measure and still land in the right place. Every loop then
    // shares one grid regardless of when it was armed.
    var phase  = Phasor.ar(K2A.ar(reset), BufRateScale.kr(bufnum), 0, frames,
        \resetPos.kr(0));
    // The input is mono, so the loop is stored mono and widened at the output. Storing
    // [dry, dry] doubled every buffer, every BufRd and every BufWr for no extra signal.
    var old    = BufRd.ar(1, bufnum, phase, loop: 1, interpolation: 1);
    // write mix: idle→writes old back, initial rec→overwrite, overdub→layer
    var wsig   = (dry * (recRun * recLevel)) + (old * preLevel);
    var out    = ((old * playing) + (dry * monLevel)) * level;   // fader scales monitor + loop
    BufWr.ar(wsig, bufnum, phase, loop: 1);
    Out.ar(0, out ! 2);
}).add;

// Same signal path, two channels through. No `! 2` at the end: the loop is already
// stereo, so widening would collapse it.
SynthDef(\looperStereo, { |bufnum, recLevel = 0, preLevel = 1, monLevel = 1.0,
        recRun = 0, playing = 0, reset = 0, level = 1.0|
    var frames = \loopFrames.kr(44100);
    var dry    = SoundIn.ar([\inChanL.ir(0), \inChanR.ir(1)]);
    var phase  = Phasor.ar(K2A.ar(reset), BufRateScale.kr(bufnum), 0, frames,
        \resetPos.kr(0));
    var old    = BufRd.ar(2, bufnum, phase, loop: 1, interpolation: 1);
    var wsig   = (dry * (recRun * recLevel)) + (old * preLevel);
    var out    = ((old * playing) + (dry * monLevel)) * level;
    BufWr.ar(wsig, bufnum, phase, loop: 1);
    Out.ar(0, out);
}).add;

// Frames needed for a ~numLoopCycles loop at a given tempo.
~loopFramesFor = { |cps|
    ((s.sampleRate ?? { s.options.sampleRate ? 44100 }) * ~numLoopCycles / cps).round.asInteger
};

// Where in the loop buffer a given Tidal cycle falls. Buffer position 0 is always a
// phrase downbeat, so this is what lets a loop be armed on ANY measure and still stack
// with the others.
~phasePosFor = { |cycle, frames|
    ((cycle % ~numLoopCycles) / ~numLoopCycles * frames).round.asInteger.clip(0, frames - 1);
};

// ── Tracks ──────────────────────────────────────────────────
// gen:        generation token — bumped on record/clear to cancel stale scheduled starts.
// startCycle: the Tidal cycle the loop was recorded from, so it can be restarted in phase.
// Re-evaluating this file is an authoring action, not a performance one: free the old
// synths AND buffers (sclang's GC never reclaims server-side buffers, so just dropping
// the reference would leak a few MB per reload). Loops survive Ctrl+., not a file reload.
~tracks !? { ~tracks.do { |t|
    t[\synth] !? { t[\synth].free };
    t[\buf]   !? { t[\buf].free };
} };
// inputs is ALWAYS a list, so mono and stereo tracks have the same shape everywhere
// downstream; only the SynthDef and the buffer's channel count differ.
~tracks = ~trackInputs.collect { |spec, i|
    (idx: i,
        name: (~trackNames !? { ~trackNames[i] }) ?? { "Track " ++ i },
        inputs: spec.asArray, state: \idle, buf: nil, synth: nil,
        gen: 0, level: 1.0, startCycle: 0)
};
if (~trackNames.notNil and: { ~trackNames.size != ~trackInputs.size }) {
    ("config.scd: ~trackNames has " ++ ~trackNames.size ++ " entries but ~trackInputs has "
        ++ ~trackInputs.size ++ " — unnamed tracks fall back to \"Track N\".").warn;
};

// ── Per-track actions ───────────────────────────────────────
~inLabel = { |t| t[\inputs].join("+") };
// Name rather than input index: "[t4 spdsx]" says far more at a glance mid-set than
// "[t4 in8]". The index stays because it is how you reach the track from the
// interpreter (~tracks[4]).
~tlabel  = { |t| "[t" ++ t[\idx] ++ " " ++ t[\name] ++ "]" };

// Cycle-quantized record → auto-play after ~numLoopCycles. Cancelable via gen.
~startRecording = { |t|
    var snapCps, snapGen, curCycle, q, target, timeToNext, minLead, wanted, frames, resetPos;
    snapCps    = ~cps;
    t[\gen]    = (t[\gen] ? 0) + 1;
    snapGen    = t[\gen];
    curCycle   = ~nowCycle.();

    // Start on the next ~recordQuantize boundary — 1 = the next measure, which is what
    // you want when you hit record. Alignment between loops does NOT depend on this:
    // the buffer is locked to the phrase grid via resetPos below, so punching in
    // mid-phrase still lands in the right place.
    q       = (~recordQuantize ? 1).max(1);
    minLead = s.latency + 0.05;              // enough lead to timestamp the reset properly
    target  = (curCycle / q).ceil * q;
    if (((target - curCycle) / snapCps) < minLead) { target = target + q };
    timeToNext     = (target - curCycle) / snapCps;
    t[\startCycle] = target;
    t[\state]      = \recording;

    // No allocation and no server round trip in the record path: the buffer already
    // exists at maximum length, so the loop length is just a number we set.
    wanted = ~loopFramesFor.(snapCps);
    frames = wanted.min(t[\bufFrames]);
    if (frames < wanted) {
        (~tlabel.(t) ++ " tempo is below ~minCps — loop truncated to "
            ++ (frames / (s.sampleRate ? 44100)).round(0.01) ++ "s. Lower ~minCps in "
            "config.scd and re-evaluate startup.scd to record this slow.").warn;
    };
    t[\loopFrames] = frames;
    resetPos       = ~phasePosFor.(target, frames);
    t[\startPhase] = resetPos / frames;       // for tools/sync-check.scd

    (~tlabel.(t) ++ " waiting " ++ timeToNext.round(0.01) ++ "s for cycle "
        ++ target.asInteger ++ " (phrase pos " ++ (t[\startPhase] * 100).round(1)
        ++ "%)...").postln;
    // Wake s.latency EARLY and timestamp the bundle for the real moment. Sending with
    // makeBundle(0) gave scsynth no lead time, so the phase reset landed ~20 ms late
    // (the "late 0.02" lines in the post window) with jitter on top. Timestamped, it
    // executes exactly on the boundary.
    SystemClock.sched((timeToNext + ~loopOffset - s.latency).max(0), {
        if (t[\gen] == snapGen) {
            s.makeBundle(s.latency, {
                t[\synth].set(\bufnum, t[\buf], \loopFrames, frames, \resetPos, resetPos,
                    \recRun, 1, \recLevel, 1, \preLevel, 0, \playing, 0, \reset, 1);
            });
            // Clearing \reset must be timestamped too. Sent untimestamped it would
            // arrive BEFORE the timestamped set above, leaving reset stuck at 1 — and
            // Phasor only resets on a RISING edge, so every later record would silently
            // fail to reset the phase.
            s.makeBundle(s.latency + 0.05, { t[\synth].set(\reset, 0) });
            // when the loop's phase actually restarts — the anchor tools/sync-check.scd
            // measures alignment against
            t[\loopStartTime] = Main.elapsedTime + s.latency;
            (~tlabel.(t) ++ " RECORDING...").postln;
            SystemClock.sched(~numLoopCycles / snapCps, {
                if (t[\gen] == snapGen) {
                    // also timestamped, so the take ends exactly one loop after it began
                    // rather than s.latency short of it
                    s.makeBundle(s.latency, {
                        t[\synth].set(\recRun, 0, \recLevel, 0, \preLevel, 1, \playing, 1);
                    });
                    t[\state] = \playing;
                    (~tlabel.(t) ++ " LOOPING").postln;
                };
                nil;
            });
        };
        nil;
    });
};

// RECORD and OVERDUB are separate actions, not one cycling button.
//
// Record starts a fresh take from ANY state, so you can punch straight over a playing
// loop without clearing it first — the old loop keeps sounding right up to the punch-in
// point, then the new take begins. ~startRecording bumps the generation token, which
// cancels anything the previous take had scheduled.
~trackRecord = { |t| ~startRecording.(t) };

// Overdub layers onto a loop that already exists, and toggles back off. It deliberately
// does nothing on an empty track: that is what record is for, and silently turning an
// overdub press into a recording would be a nasty surprise mid-set.
~trackOverdub = { |t|
    switch (t[\state],
        \playing, {
            t[\synth].set(\recRun, 1, \recLevel, 1, \preLevel, 1, \playing, 1);
            t[\state] = \overdub;
            (~tlabel.(t) ++ " OVERDUBBING").postln;
        },
        \overdub, {
            t[\synth].set(\recRun, 0, \recLevel, 0, \preLevel, 1, \playing, 1);
            t[\state] = \playing;
            (~tlabel.(t) ++ " PLAYING").postln;
        },
        { (~tlabel.(t) ++ " overdub ignored — nothing recorded yet").postln }
    );
};

// Clear / delete: stop and cancel anything pending.
~trackClear = { |t|
    t[\gen] = (t[\gen] ? 0) + 1;
    t[\synth] !? { t[\synth].set(\recRun, 0, \recLevel, 0, \preLevel, 1, \playing, 0) };
    t[\state] = \idle;
    (~tlabel.(t) ++ " CLEARED").postln;
};

// ── Navigation ──────────────────────────────────────────────
// Stepping onto a track selects it outright — there is no separate cursor to commit.
// Wraps rather than clamps: on a controller, running off the end and stopping feels
// broken, and there is no scrollbar to tell you where you are.
~navMove = { |delta = 1|
    var n = ~tracks.size;
    if (n > 0) {
        ~focus = ((~focus ? 0) + delta) % n;
        ("-> t" ++ ~focus ++ " " ++ ~tracks[~focus][\name]).postln;
    };
    ~focus;
};

// Jump straight to a track (the dashboard's click).
~navFocus = { |i|
    ~focus = i.clip(0, ~tracks.size - 1);
    ("-> t" ++ ~focus ++ " " ++ ~tracks[~focus][\name]).postln;
    ~focus;
};

// Fader.
~trackLevel = { |t, lvl|
    t[\level] = lvl;
    t[\synth] !? { t[\synth].set(\level, lvl) };
};

// ── Panic recovery ──────────────────────────────────────────
// Re-arm a loop that was playing when the node tree got flushed. Because the buffer is
// locked to the phrase grid, this can re-enter on ANY measure — we just reset to the
// buffer position that measure corresponds to. It used to have to wait for the loop's
// own boundary, up to a full phrase.
~restoreTrack = { |t|
    var snapGen, cps, now, target, wait, resetPos;
    t[\gen]   = (t[\gen] ? 0) + 1;
    snapGen   = t[\gen];
    t[\state] = \playing;
    cps       = (~cps ? 0.5).max(0.001);
    now       = ~nowCycle.();
    target    = now.ceil;
    if (((target - now) / cps) < (s.latency + 0.05)) { target = target + 1 };
    wait      = (target - now) / cps;
    resetPos  = ~phasePosFor.(target, t[\loopFrames]);
    t[\startPhase] = resetPos / t[\loopFrames];
    (~tlabel.(t) ++ " restoring in " ++ wait.round(0.01) ++ "s...").postln;
    SystemClock.sched((wait - s.latency).max(0), {
        if (t[\gen] == snapGen) {
            s.makeBundle(s.latency, {
                t[\synth].set(\bufnum, t[\buf], \loopFrames, t[\loopFrames],
                    \resetPos, resetPos,
                    \recRun, 0, \recLevel, 0, \preLevel, 1, \playing, 1, \reset, 1);
            });
            // timestamped clear — see the note in ~startRecording. Sent untimestamped it
            // would land before the set above and leave reset stuck at 1, so the NEXT
            // record would silently fail to reset the phase.
            s.makeBundle(s.latency + 0.05, { t[\synth].set(\reset, 0) });
            t[\loopStartTime] = Main.elapsedTime + s.latency;
            (~tlabel.(t) ++ " LOOPING").postln;
        };
        nil;
    });
};

// Build the track synths — and rebuild them after every Ctrl+.
// Ctrl+. sends /g_freeAll, which kills these synths along with everything else. It does
// NOT free buffers, so the recorded audio is still there and the loops can be re-armed.
~buildTracks !? { ServerTree.remove(~buildTracks, s) };   // don't stack on re-eval
~buildTracks = {
    // \overdub means a full loop is already committed to the buffer, so it resumes too;
    // \recording was a half-finished take, so that one just drops to idle.
    var resume = ~tracks.collect { |t|
        #[\playing, \overdub].includes(t[\state]) and: { t[\buf].notNil }
    };
    ~tracks.do { |t|
        t[\state] = \idle;
        t[\buf] !? {
            var ins  = t[\inputs];
            var args = [bufnum: t[\buf], loopFrames: t[\loopFrames], recLevel: 0,
                preLevel: 1, monLevel: ~monLevel, recRun: 0, playing: 0, level: t[\level]];
            t[\synth] = if (ins.size >= 2) {
                Synth(\looperStereo, args ++ [inChanL: ins[0], inChanR: ins[1]]);
            } {
                Synth(\looperMono, args ++ [inChan: ins[0]]);
            };
        };
    };
    if (~restoreLoopsOnPanic) {
        ~tracks.do { |t, i| if (resume[i]) { ~restoreTrack.(t) } };
    };
};
ServerTree.add(~buildTracks, s);

// A server quit/reboot invalidates every buffer, so drop the references. Otherwise the
// ServerTree hook above would fire on the next boot and build synths around dead
// bufnums, flooding the post window until you re-evaluated startup.scd.
~forgetTracks !? { ServerQuit.remove(~forgetTracks, s) };
~forgetTracks = {
    ~tracks.do { |t|
        t[\buf] = nil; t[\synth] = nil; t[\state] = \idle;
        t[\bufFrames] = nil; t[\loopFrames] = nil;
    };
};
ServerQuit.add(~forgetTracks, s);

// First build by hand — ServerTree only fires on boot/panic, not on a plain reload.
// s.sync waits for the SynthDef and then for the buffers to actually exist, rather than
// assuming they will by some fixed delay.
//
// Buffers are allocated ONCE here, mono, at the length the slowest supported tempo
// (~minCps) needs. Recording then never allocates — it only moves \loopFrames.
fork {
    var maxFrames, mb, chans;
    s.sync;
    maxFrames = ~loopFramesFor.(~minCps);
    chans     = 0;
    ~tracks.do { |t|
        var nch = t[\inputs].size.clip(1, 2);      // stereo costs twice the buffer
        chans          = chans + nch;
        t[\buf]        = Buffer.alloc(s, maxFrames, nch);
        t[\bufFrames]  = maxFrames;
        t[\loopFrames] = ~loopFramesFor.(~cps).min(maxFrames);
    };
    s.sync;
    ~buildTracks.value;
    mb = (maxFrames * 4 * chans / 1e6).round(0.1);
    ("Multitrack ready: " ++ ~tracks.size ++ " tracks ("
        ++ ~tracks.collect({ |t| t[\name] ++ "=" ++ ~inLabel.(t) }).join(", ") ++ ")"
        ++ " | " ++ (maxFrames / (s.sampleRate ? 44100)).round(0.1) ++ "s max loop, "
        ++ mb ++ " MB total").postln;
};

// ── MIDI — one pad per track, no focus mode ─────────────────
// connectAll is safe to re-run: it disconnects first when already initialised, so
// reloading this file re-scans for newly plugged gear without duplicating events.
MIDIIn.connectAll;

// Resolve a MIDI source id to something human — essential once more than one controller
// is plugged in, since note numbers collide across devices.
~midiDevName = { |src|
    var ep = MIDIClient.sources !? { MIDIClient.sources.detect { |e| e.uid == src } };
    ep !? { ep.device ++ " / " ++ ep.name } ? ("uid " ++ src);
};

// ~midiDebug (config.scd) prints every incoming message. Leave it OFF for a show —
// posting on every pad hit stalls the IDE, and the SPD sends a lot of them.
// For mapping a new controller use tools/midi-monitor.scd instead: it also prints a
// summary table of everything it saw.
MIDIdef.noteOn(\midiPrint, { |vel, note, chan, src|
    if (~midiDebug) {
        ("MIDI note=" ++ note ++ " vel=" ++ vel ++ " ch=" ++ chan
            ++ "   [" ++ ~midiDevName.(src) ++ "]").postln;
    };
}).fix;
MIDIdef.cc(\midiCcPrint, { |val, num, chan, src|
    if (~midiDebug) {
        ("MIDI CC=" ++ num ++ " val=" ++ val ++ " ch=" ++ chan
            ++ "   [" ++ ~midiDevName.(src) ++ "]").postln;
    };
}).fix;

// The old single-pedal handler drove whichever track was FOCUSED. It is gone, but a
// running session keeps MIDIdefs by key, so free it explicitly — otherwise reloading
// this file would leave it firing alongside the new map. That matters more than usual
// here: its notes were 60/61, which on channel 0 are MPK KEYBOARD keys, so playing the
// keys would silently start and clear recordings.
MIDIdef.all[\looperPedal] !? { |d| d.free };

// Three pads, one job each, always acting on the SELECTED track (~focus, set from the
// dashboard or the controller). Three fixed pads scale to any number of tracks, where a
// pad per track does not — and separating record from overdub is what lets you punch a
// new take over a playing loop without clearing it first.
// .fix keeps them alive through Ctrl+.; without it a panic stop leaves you with no way
// to drive the loopers until you re-evaluate the file.
MIDIdef.noteOn(\looperPads, { |vel, note, chan|
    if (chan == ~midiChan) {
        var t = ~tracks[(~focus ? 0).clip(0, ~tracks.size - 1)];
        if (note == ~padRecord)  { ~trackRecord.(t) };
        if (note == ~padOverdub) { ~trackOverdub.(t) };
        if (note == ~padClear)   { ~trackClear.(t) };
    };
}).fix;

// Knobs are absolute, not soft-takeover: the first move jumps the fader to wherever the
// knob physically sits. Predictable, and there is no way to read a knob's position until
// it is touched.
MIDIdef.cc(\looperKnobs, { |val, num, chan|
    if (chan == ~midiChan) {
        ~knobFader !? { |m|
            m.indexOf(num) !? { |i| ~tracks[i] !? { |t| ~trackLevel.(t, val / 127) } };
        };
    };
}).fix;

("=== looper.scd loaded — " ++ ~trackInputs.size ++ " tracks"
    ++ " | MIDI ch " ++ ~midiChan
    ++ " | rec " ++ ~padRecord ++ " dub " ++ ~padOverdub ++ " clr " ++ ~padClear
    ++ " | fader cc " ++ ~knobFader
    ++ " ===").postln;
