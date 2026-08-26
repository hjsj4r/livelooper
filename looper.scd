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
// One Phasor drives both read and write, so the record head can never drift from the
// play head and overdub layers in place. resetPos locks the buffer to the phrase grid:
// punch in halfway through a phrase and the reset jumps to the matching point in the
// buffer, so every loop shares one grid regardless of when it was armed.
//
// THE LOOP JOIN
// A take is recorded for its musical length PLUS an overlap tail. The loop region is
// [0, frames); the tail lives just past it at [frames, frames + xfFrames) and holds a
// second pass over the same musical span. Playback crossfades the tail out against the
// loop's start, so the join is a blend instead of a butt splice.
//
// The seam sits at resetPos — where the take started, and therefore where it ended.
// `j` is how far past that seam the play head is.
//
// Curve: fade-in is t^c and fade-out (1-t)^c. At c = 0.5 the squares sum to 1, i.e.
// EQUAL POWER; at c = 1 it is linear/equal gain. Above 1 the join stretches out.
//
// The tail is written by the SAME BufWr, redirected: while recording past `frames` the
// write index jumps to the tail region, so the loop's start is preserved rather than
// being overwritten by the second pass. Read and write stay at the same index at all
// other times, which is what keeps overdub layering in place.
~looperGraph = { |nch|
    var inChans  = if (nch >= 2) { [\inChanL.ir(0), \inChanR.ir(1)] } { \inChan.ir(0) };
    var bufnum   = \bufnum.kr(0);
    var recLevel = \recLevel.kr(0), preLevel = \preLevel.kr(1);
    var monLevel = \monLevel.kr(1.0), recRun = \recRun.kr(0);
    var playing  = \playing.kr(0), reset = \reset.kr(0), level = \level.kr(1.0);
    var frames   = \loopFrames.kr(44100);
    var resetPos = \resetPos.kr(0);
    var xf       = \xfFrames.kr(0);
    var curve    = \xfCurve.kr(0.5);
    var dry      = SoundIn.ar(inChans);
    var phase    = Phasor.ar(K2A.ar(reset), BufRateScale.kr(bufnum), 0, frames, resetPos);
    // samples since this take began — places the overlap tail
    var n        = Sweep.ar(K2A.ar(reset), SampleRate.ir);
    var inTail   = ((n >= frames) * recRun).clip(0, 1);
    var tailPos  = (n - frames).max(0);
    var j        = (phase - resetPos + frames) % frames;
    // +1 so that xf = 1 (the disabled case) gives t = 1 everywhere and no blend at all
    var t        = ((j + 1) / xf.max(1)).clip(0, 1);
    var head     = BufRd.ar(nch, bufnum, phase, loop: 1, interpolation: 1);
    var tail     = BufRd.ar(nch, bufnum, frames + j, loop: 1, interpolation: 1);
    var old      = (head * t.pow(curve)) + (tail * (1 - t).pow(curve));
    // arithmetic blend rather than Select, so it expands cleanly over 2 channels
    var wIdx     = (phase * (1 - inTail)) + ((frames + tailPos) * inTail);
    var normal   = (dry * (recRun * recLevel)) + (head * preLevel);
    var wsig     = (normal * (1 - inTail)) + (dry * inTail);
    // `head`, not `old` — writing the crossfaded signal back would bake the join in
    // again on every pass
    var out      = ((old * playing) + (dry * monLevel)) * level;
    BufWr.ar(wsig, bufnum, wIdx, loop: 1);
    Out.ar(\outBus.ir(0), if (nch >= 2) { out } { out ! 2 });
};

// Two defs, because BufRd/BufWr channel counts are fixed when the SynthDef is built.
// A mono jack gets \looperMono; a stereo pair gets \looperStereo, whose two channels are
// separate ir controls so the pair need not be adjacent.
SynthDef(\looperMono,   { ~looperGraph.(1) }).add;
SynthDef(\looperStereo, { ~looperGraph.(2) }).add;

// One FX synth per track, reading that track's private bus and writing to the main out.
// Kept OUT of the looper def on purpose: the record path took real work to get right and
// should not be recompiled every time an effect changes. It also means loopers can sit at
// the head of the node tree and FX at the tail, so ordering is automatic.
//
// Guitar drive. The pre-highpass matters more than the clipper itself — an amp rolls the
// lows off BEFORE its distortion stage, and skipping that is what makes naive soft-clip
// sound like mud on a low string. The post low-pass stands in for a speaker cab.
//
// At drive 0 the crossfade sits fully on the dry signal, so this is a true bypass.
SynthDef(\trackFx, { |inBus = 0, out = 0, level = 1|
    // Lag: R2 arrives quantised from the browser, and stepping straight to each new value
    // would zipper. 20 ms is short enough to still feel immediate under the finger.
    var drive = Lag.kr(\drive.kr(0).clip(0, 1), 0.02);
    var tone  = \tone.kr(0.5);
    var dry   = In.ar(inBus, 2);
    var pre   = HPF.ar(dry, \preHighpass.kr(120));
    var hot   = (pre * (1 + (drive * 40))).tanh;
    var wet   = LPF.ar(hot, tone.linexp(0, 1, 1800, 6000));
    // level-compensate, or leaning on the trigger doubles as a volume pedal
    var sig   = XFade2.ar(dry, wet * (1 / (1 + (drive * 4))), (drive * 2) - 1);
    Out.ar(out, sig * level);
}).add;

~srate = { s.sampleRate ?? { s.options.sampleRate ? 44100 } };

// Frames for a loop of `cycles` bars at a given tempo. Cycles defaults to the config
// value so existing callers keep working.
~loopFramesFor = { |cps, cycles|
    (~srate.() * (cycles ? ~numLoopCycles) / cps).round.asInteger
};

// Length of the recorded overlap tail, in frames.
~xfadeFrames = { (~srate.() * (~xfadeSecs ? 0)).round.asInteger.max(0) };

// Where in the loop buffer a given Tidal cycle falls. Buffer position 0 is always a
// phrase downbeat, so this is what lets a loop be armed on ANY measure and still stack
// with the others.
// Cycles is the TRACK's own length, not the global default: a 4-bar loop locks to
// cycle % 4 and an 8-bar loop to cycle % 8, and because 4 divides 8 they still line up.
~phasePosFor = { |cycle, frames, cycles|
    var c = cycles ? ~numLoopCycles;
    ((cycle % c) / c * frames).round.asInteger.clip(0, frames - 1);
};

// ── Tracks ──────────────────────────────────────────────────
// gen:        generation token — bumped on record/clear to cancel stale scheduled starts.
// startCycle: the Tidal cycle the loop was recorded from, so it can be restarted in phase.
// Re-evaluating this file is an authoring action, not a performance one: free the old
// synths AND buffers (sclang's GC never reclaims server-side buffers, so just dropping
// the reference would leak a few MB per reload). Loops survive Ctrl+., not a file reload.
~tracks !? { ~tracks.do { |t|
    t[\synth]   !? { t[\synth].free };
    t[\fxSynth] !? { t[\fxSynth].free };
    t[\buf]     !? { t[\buf].free };
    t[\fxBus]   !? { t[\fxBus].free };
} };
// inputs is ALWAYS a list, so mono and stereo tracks have the same shape everywhere
// downstream; only the SynthDef and the buffer's channel count differ.
~tracks = ~trackInputs.collect { |spec, i|
    (idx: i,
        name: (~trackNames !? { ~trackNames[i] }) ?? { "Track " ++ i },
        inputs: spec.asArray, state: \idle, buf: nil, synth: nil,
        fxBus: nil, fxSynth: nil, fx: 0.0, cycles: (~numLoopCycles ? 4),
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
    var cyc, xfFrames, takeSecs;
    snapCps    = ~cps;
    cyc        = t[\cycles] ? ~numLoopCycles;
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
    // The overlap tail lives past the loop region, so it has to fit inside the buffer too.
    xfFrames = ~xfadeFrames.().min((t[\bufFrames] / 4).asInteger);
    wanted   = ~loopFramesFor.(snapCps, cyc);
    frames   = wanted.min(t[\bufFrames] - xfFrames);
    if (frames < wanted) {
        (~tlabel.(t) ++ " tempo is below ~minCps for a " ++ cyc ++ "-bar loop — truncated to "
            ++ (frames / ~srate.()).round(0.01) ++ "s. Lower ~minCps (or ~maxLoopCycles) in "
            "config.scd and re-evaluate startup.scd to record this long.").warn;
    };
    t[\loopFrames] = frames;
    t[\xfFrames]   = xfFrames;
    resetPos       = ~phasePosFor.(target, frames, cyc);
    t[\startPhase] = resetPos / frames;       // for tools/sync-check.scd
    takeSecs       = (cyc / snapCps) + (xfFrames / ~srate.());

    (~tlabel.(t) ++ " waiting " ++ timeToNext.round(0.01) ++ "s for cycle "
        ++ target.asInteger ++ "  (" ++ cyc ++ " bars, phrase pos "
        ++ (t[\startPhase] * 100).round(1) ++ "%, join "
        ++ (xfFrames / ~srate.() * 1000).round(1) ++ "ms)...").postln;
    // Wake s.latency EARLY and timestamp the bundle for the real moment. Sending with
    // makeBundle(0) gave scsynth no lead time, so the phase reset landed ~20 ms late
    // (the "late 0.02" lines in the post window) with jitter on top. Timestamped, it
    // executes exactly on the boundary.
    SystemClock.sched((timeToNext + ~loopOffset - s.latency).max(0), {
        if (t[\gen] == snapGen) {
            s.makeBundle(s.latency, {
                t[\synth].set(\bufnum, t[\buf], \loopFrames, frames, \resetPos, resetPos,
                    \xfFrames, xfFrames, \xfCurve, (~xfadeCurve ? 0.5),
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
            // Playback starts at the MUSICAL end, so the loop comes in seamlessly...
            SystemClock.sched(cyc / snapCps, {
                if (t[\gen] == snapGen) {
                    // also timestamped, so the take ends exactly one loop after it began
                    // rather than s.latency short of it
                    s.makeBundle(s.latency, { t[\synth].set(\playing, 1) });
                    t[\state] = \playing;
                    (~tlabel.(t) ++ " LOOPING").postln;
                };
                nil;
            });
            // ...while recording carries on into the overlap tail. The play head is
            // already reading that tail as it is written — both advance one sample per
            // frame from the same instant, so the crossfade works from the first pass.
            SystemClock.sched(takeSecs, {
                if (t[\gen] == snapGen) {
                    s.makeBundle(s.latency, {
                        t[\synth].set(\recRun, 0, \recLevel, 0, \preLevel, 1);
                    });
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
// The list is the tracks PLUS two mixer items — the Tidal patterns level and the click
// level — so the stick can reach every fader without a mode. Anything at or past
// ~tracks.size is one of those, which is also how the transport buttons know to do
// nothing there: you cannot "record" the click.
~navSize   = { ~tracks.size + 2 };
~navIsTrack = { |i| (i ? ~focus ? 0) < ~tracks.size };
~navName   = { |i|
    var k = i ? (~focus ? 0);
    if (k < ~tracks.size) { ~tracks[k][\name] }
        { if (k == ~tracks.size) { "tidal level" } { "click level" } };
};

// Stepping onto an item selects it outright — there is no separate cursor to commit.
// Wraps rather than clamps: on a controller, running off the end and stopping feels
// broken, and there is no scrollbar to tell you where you are.
~navMove = { |delta = 1|
    ~focus = ((~focus ? 0) + delta) % ~navSize.();
    ("-> " ++ ~focus ++ " " ++ ~navName.()).postln;
    ~focus;
};

~navFocus = { |i|
    ~focus = i.clip(0, ~navSize.() - 1);
    ("-> " ++ ~focus ++ " " ++ ~navName.()).postln;
    ~focus;
};

// Left/right on the stick nudges whatever is selected. Deltas rather than absolutes,
// because the browser has no authoritative copy of the level — SC does.
~navAdjust = { |delta|
    var i = ~focus ? 0;
    var cur, next;
    case
    { ~navIsTrack.(i) } {
        cur  = ~tracks[i][\level] ? 1.0;
        next = (cur + delta).clip(0, 1);
        ~trackLevel.(~tracks[i], next);
    }
    { i == ~tracks.size } {
        ~dirtLevel = ((~dirtLevel ? 1.0) + delta).clip(0, 1);
        ~dirtFader !? { ~dirtFader.set(\level, ~dirtLevel) };
        next = ~dirtLevel;
    }
    {
        ~clickAmp = ((~clickAmp ? 0.5) + delta).clip(0, 1);
        next = ~clickAmp;
    };
    next;
};

// Loop length in bars, for the NEXT recording on this track. Existing audio keeps the
// length it was cut at, so changing this never disturbs a loop already playing.
~trackCycles = { |t, n|
    var choices = ~loopCycleChoices ? [4, 8];
    t[\cycles] = n.clip(choices.minItem, choices.maxItem).asInteger;
    (~tlabel.(t) ++ " next take: " ++ t[\cycles] ++ " bars").postln;
    t[\cycles];
};

// Step to the next available length — what a single button or dashboard click does.
~trackCyclesNext = { |t|
    var choices = ~loopCycleChoices ? [4, 8];
    var i = choices.indexOf(t[\cycles] ? choices.first) ? 0;
    ~trackCycles.(t, choices[(i + 1) % choices.size]);
};

// Drive amount, 0..1. Comes from the R2 trigger, so it is called often — it does nothing
// but a .set, and the synth lags the value itself.
~trackFx = { |t, amt|
    t[\fx] = amt.clip(0, 1) * (~fxDriveMax ? 1.0);
    t[\fxSynth] !? { t[\fxSynth].set(\drive, t[\fx]) };
    t[\fx];
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
    resetPos  = ~phasePosFor.(target, t[\loopFrames], t[\cycles]);
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
        (t[\buf].notNil and: { t[\fxBus].notNil }) .if {
            var ins  = t[\inputs];
            var args = [bufnum: t[\buf], loopFrames: t[\loopFrames],
                xfFrames: (t[\xfFrames] ? 0), xfCurve: (~xfadeCurve ? 0.5), recLevel: 0,
                preLevel: 1, monLevel: ~monLevel, recRun: 0, playing: 0,
                level: t[\level], outBus: t[\fxBus]];
            t[\synth] = if (ins.size >= 2) {
                Synth(\looperStereo, args ++ [inChanL: ins[0], inChanR: ins[1]]);
            } {
                Synth(\looperMono, args ++ [inChan: ins[0]]);
            };
            // addToTail so the FX always runs after every looper. Order among the FX
            // synths themselves is irrelevant — each reads its own private bus.
            t[\fxSynth] = Synth(\trackFx, [
                inBus: t[\fxBus], out: 0, drive: (t[\fx] ? 0),
                tone: ~fxTone, preHighpass: ~fxPreHighpass
            ], addAction: \addToTail);
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
        t[\fxBus] = nil; t[\fxSynth] = nil;
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
    // Sized for the LONGEST selectable loop at the SLOWEST supported tempo, plus room
    // for the overlap tail. Everything shorter just wraps earlier inside it.
    maxFrames = ~loopFramesFor.(~minCps, ~maxLoopCycles ? ~numLoopCycles) + ~xfadeFrames.();
    chans     = 0;
    ~tracks.do { |t|
        var nch = t[\inputs].size.clip(1, 2);      // stereo costs twice the buffer
        chans          = chans + nch;
        t[\buf]        = Buffer.alloc(s, maxFrames, nch);
        t[\bufFrames]  = maxFrames;
        t[\cycles]     = t[\cycles] ? ~numLoopCycles;
        t[\xfFrames]   = ~xfadeFrames.();
        t[\loopFrames] = ~loopFramesFor.(~cps, t[\cycles]).min(maxFrames - t[\xfFrames]);
        // the looper's output always ends up stereo, so the FX bus is stereo either way
        t[\fxBus]      = Bus.audio(s, 2);
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
    // Silently ignored when the selection is on a mixer item rather than a track —
    // there is no such thing as recording the click.
    if ((chan == ~midiChan) and: { ~navIsTrack.() }) {
        var t = ~tracks[~focus ? 0];
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
