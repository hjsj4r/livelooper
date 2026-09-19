// ============================================================
//  LIVE LOOPER  ·  looper.scd   (multitrack)
//  Loaded by startup.scd once the server is up.
//  One independent loop per input: record / overdub / clear + a fader each.
//  Controlled from the dashboard and the DualSense; both act on the SELECTED track.
//  Tracks can be added, removed, re-wired and renamed while the rig runs:
//      ~addTrack.(5, "bass");   ~addTrack.([0, 1], "mic");
//      ~setTrackInput.(2, 7);   ~renameTrack.(2, "synth");   ~removeTrack.(2);
// ============================================================

// ── Settings come from config.scd ───────────────────────────
// (~trackInputs, ~numLoopCycles, ~loopOffset, ~monLevel, ~restoreLoopsOnPanic,
//  ~headFadeSecs, ~tailSecs, ~tailCurve, ~numLoopCycles, ~minCps, ~fx*)
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
// THE LOOP JOIN — two independent fades, not one crossfade
// A take is recorded for its musical length PLUS a tail. The loop region is [0, frames);
// the tail lives just past it at [frames, frames + tailFrames) and holds whatever was
// still sounding when the loop ended — a cymbal decaying, a note ringing.
//
// The seam sits at resetPos: where the take started, and therefore where it ended.
// `j` is how far past that seam the play head is.
//
// These used to be one number (~xfadeSecs) and could not both be right, because they
// want opposite things:
//
//   HEAD FADE  (headFrames, ~3 ms) exists only to remove the step discontinuity at the
//   seam, which is what clicks. It must stay far shorter than an attack transient
//   (10-50 ms) or a hit on beat 1 is heard arriving soft. Linear.
//
//   TAIL       (tailFrames, hundreds of ms) is the genuine CONTINUATION of the same
//   performance — buf[frames] is literally the sample after buf[frames-1] — played back
//   ADDED on top of the loop start and decaying over its own length. A crash rings on
//   into the next repetition, exactly as it would if a drummer repeated the phrase.
//
// Because the tail is a continuation and not a second copy of the head, there is no
// equal-power/equal-gain question left to get wrong: the head is the signal at full gain
// and the tail is a ghost decaying away. tailCurve < 1 holds the tail near full early,
// which preserves the natural shape of the decay.
//
// Continuity across the seam comes from the TAIL, not from the head fade: at the wrap
// the head is still near zero while the tail delivers buf[frames], which follows
// buf[frames-1] with no step at all.
//
// The tail is written by the SAME BufWr, redirected: while recording inside the tail
// WINDOW the write index jumps past the loop region, so the loop's start is preserved
// rather than overwritten. That window is bounded at BOTH ends — an overdub happens
// thousands of frames later and must write in place, or it lands at a drifting offset
// and smears the loop across the buffer.
~looperGraph = { |nch|
    // kr, not ir: the input index is a bus number In reads at control rate, so re-wiring
    // a track to another jack is a .set — no rebuild, no dropout, the loop keeps playing.
    // Only the channel COUNT is baked in (BufRd/BufWr widths), which is why mono<->stereo
    // still means a new synth and a new buffer.
    var inChans  = if (nch >= 2) { [\inChanL.kr(0), \inChanR.kr(1)] } { \inChan.kr(0) };
    var bufnum   = \bufnum.kr(0);
    var recLevel = \recLevel.kr(0), preLevel = \preLevel.kr(1);
    var monLevel = \monLevel.kr(1.0), recRun = \recRun.kr(0);
    var playing  = \playing.kr(0), reset = \reset.kr(0), level = \level.kr(1.0);
    var frames   = \loopFrames.kr(44100);
    var resetPos = \resetPos.kr(0);
    var hf       = \headFrames.kr(0);
    var tf       = \tailFrames.kr(0);
    var tailCur  = \tailCurve.kr(0.5);
    var dry      = SoundIn.ar(inChans);
    var phase    = Phasor.ar(K2A.ar(reset), BufRateScale.kr(bufnum), 0, frames, resetPos);
    // samples since this take began — places the overlap tail
    var n        = Sweep.ar(K2A.ar(reset), SampleRate.ir);
    // Bounded at BOTH ends. Open-ended (n >= frames) stayed true forever once a take
    // had finished, so an overdub — which raises recRun without resetting n — had every
    // sample redirected past the loop region at a drifting offset instead of layering
    // in place.
    var inTail   = ((n >= frames) * (n < (frames + tf)) * recRun).clip(0, 1);
    var tailPos  = (n - frames).max(0);
    var j        = (phase - resetPos + frames) % frames;
    // +1 so a zero-length head fade gives full gain from the very first sample rather
    // than silence — that is what makes 0 an exact bypass, not a one-sample dip.
    var gHead    = ((j + 1) / hf.max(1)).clip(0, 1);
    // ...and so tf = 0 gives a tail gain of exactly 0 everywhere.
    var gTail    = (1 - ((j + 1) / tf.max(1)).clip(0, 1)).pow(tailCur);
    var head     = BufRd.ar(nch, bufnum, phase, loop: 1, interpolation: 1);
    // clamped so the read never wanders past the tail region into unwritten buffer
    var tail     = BufRd.ar(nch, bufnum, frames + j.min(tf), loop: 1, interpolation: 1);
    var old      = (head * gHead) + (tail * gTail);
    // arithmetic blend rather than Select, so it expands cleanly over 2 channels
    var wIdx     = (phase * (1 - inTail)) + ((frames + tailPos) * inTail);
    var normal   = (dry * (recRun * recLevel)) + (head * preLevel);
    var wsig     = (normal * (1 - inTail)) + (dry * inTail);
    // `head`, not `old` — writing the joined signal back would bake the fade and the
    // tail into the loop again on every pass
    var out      = ((old * playing) + (dry * monLevel)) * level;
    BufWr.ar(wsig, bufnum, wIdx, loop: 1);
    // Meters for the dashboard: what is arriving at the jack, and what the loop itself
    // is putting out. Silent at meterRate 0 (Impulse never fires again after its first
    // tick), which is the state until a dashboard subscribes — so a closed dashboard
    // costs nothing here, and the idle-traffic guarantee holds. Identified by node ID on
    // the sclang side, since a track's index can change when one is removed.
    SendReply.kr(Impulse.kr(\meterRate.kr(0)), '/trkMeter', [
        Amplitude.kr(Mix(dry) / nch, 0.01, 0.15),
        Amplitude.kr(Mix(old * playing * level) / nch, 0.01, 0.15)
    ]);
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
~headFadeFrames   = { (~srate.() * (~headFadeSecs   ? 0)).round.asInteger.max(0) };
~headWindowFrames = { (~srate.() * (~headWindowSecs ? 0)).round.asInteger.max(0) };
~tailFrames     = { (~srate.() * (~tailSecs     ? 0)).round.asInteger.max(0) };

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
//
// The layout — which tracks exist, fed by which jacks, called what — lives in
// ~trackInputs / ~trackNames. config.scd sets them at boot; ~addTrack and friends change
// them in the session; Save writes them back. Loading this file (re)builds ~tracks from
// them, so a reload and a device reboot both come back with the layout you had.
//
// inputs is ALWAYS a list, so mono and stereo tracks have the same shape everywhere
// downstream; only the SynthDef and the buffer's channel count differ.
~newTrack = { |spec, name, i|
    (idx: i, name: (name ?? { "Track " ++ i }).asString,
        inputs: spec.asArray, state: \idle, buf: nil, synth: nil,
        fxBus: nil, fxSynth: nil, fx: 0.0, cycles: (~numLoopCycles ? 4),
        gen: 0, level: 1.0, startCycle: 0)
};
// Something the dashboard can watch: bumped whenever the set of strips changes shape,
// so it rebuilds them exactly then and never polls names.
~layoutGen = ~layoutGen ? 0;
~tracks    = ~tracks ? [];
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
    var cyc, headFrames, tailFrames, hwFrames, takeSecs;
    snapCps    = ~cps;
    cyc        = t[\cycles] ? ~numLoopCycles;
    t[\gen]    = (t[\gen] ? 0) + 1;
    // cancels any loop stop/start still waiting on a bar line — otherwise it would fire
    // during the new take and mute it
    t[\muteGen] = (t[\muteGen] ? 0) + 1;
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
    // The tail lives past the loop region, so it has to fit inside the buffer too. The
    // quarter-buffer cap is what stops a long ~tailSecs from eating the loop itself.
    headFrames = ~headFadeFrames.();
    tailFrames = ~tailFrames.().min((t[\bufFrames] / 4).asInteger);
    hwFrames   = ~headWindowFrames.();
    wanted     = ~loopFramesFor.(snapCps, cyc);
    frames     = wanted.min(t[\bufFrames] - tailFrames);
    if (frames < wanted) {
        (~tlabel.(t) ++ " tempo is below ~minCps for a " ++ cyc ++ "-bar loop — truncated to "
            ++ (frames / ~srate.()).round(0.01) ++ "s. Lower ~minCps (or ~maxLoopCycles) in "
            "config.scd and re-evaluate startup.scd to record this long.").warn;
    };
    t[\loopFrames] = frames;
    t[\headFrames] = headFrames;
    t[\tailFrames] = tailFrames;
    // THE HEAD WINDOW moves the SEAM, not the audio.
    // Recording opens hwFrames early and the loop's origin moves back by exactly the
    // same amount, so buffer position and musical time stay locked together — the loop
    // still plays every note where you played it. What changes is where the circle is
    // cut: hwFrames before the downbeat instead of on it.
    //
    // That matters because the buffer is a closed circle of exactly `frames`. The audio
    // just BEFORE the seam is written at the END of the take — a different pass. So a
    // strike played early against a seam sitting on the downbeat has its onset in one
    // pass and its body in another, and the loop replays a truncated attack. Cutting the
    // circle a few tens of milliseconds earlier puts the whole strike on one side of it.
    //
    // NOT the same knob as ~loopOffset, which moves the audio against the grid. This
    // moves the grid's cut point against the audio, and the loop stays exactly one
    // phrase long either way, so nothing drifts.
    hwFrames       = hwFrames.min((frames / 4).asInteger);
    resetPos       = (~phasePosFor.(target, frames, cyc) - hwFrames + frames) % frames;
    t[\headWindow] = hwFrames;
    t[\startPhase] = resetPos / frames;       // for tools/sync-check.scd
    takeSecs       = (cyc / snapCps) + (tailFrames / ~srate.());

    (~tlabel.(t) ++ " waiting " ++ timeToNext.round(0.01) ++ "s for cycle "
        ++ target.asInteger ++ "  (" ++ cyc ++ " bars, phrase pos "
        ++ (t[\startPhase] * 100).round(1) ++ "%, head "
        ++ (headFrames / ~srate.() * 1000).round(1) ++ "ms, window "
        ++ (hwFrames / ~srate.() * 1000).round(1) ++ "ms, tail "
        ++ (tailFrames / ~srate.() * 1000).round(1) ++ "ms)...").postln;
    // Wake s.latency EARLY and timestamp the bundle for the real moment. Sending with
    // makeBundle(0) gave scsynth no lead time, so the phase reset landed ~20 ms late
    // (the "late 0.02" lines in the post window) with jitter on top. Timestamped, it
    // executes exactly on the boundary.
    SystemClock.sched(
        (timeToNext + ~loopOffset - (hwFrames / ~srate.()) - s.latency).max(0), {
        if (t[\gen] == snapGen) {
            s.makeBundle(s.latency, {
                t[\synth].set(\bufnum, t[\buf], \loopFrames, frames, \resetPos, resetPos,
                    \headFrames, headFrames, \tailFrames, tailFrames,
                    \tailCurve, (~tailCurve ? 0.5),
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
    t[\gen]     = (t[\gen] ? 0) + 1;
    t[\muteGen] = (t[\muteGen] ? 0) + 1;
    t[\synth] !? { t[\synth].set(\recRun, 0, \recLevel, 0, \preLevel, 1, \playing, 0) };
    t[\state] = \idle;
    (~tlabel.(t) ++ " CLEARED").postln;
};

// ── Stop / start a loop on the grid ─────────────────────────
// Silence a loop and bring it back without losing it, quantized to the bar.
//
// The Phasor is never stopped, only muted, which is the whole trick: the play head keeps
// running through the silence, so whenever you bring the loop back it is exactly where it
// would have been had it never stopped. That is why ANY bar line is a safe re-entry —
// there is no "wait for the top of the phrase", and the loop can never come back flammed
// against the others.
//
// \stopping and \starting are real states, not cosmetic: the dashboard shows the toggle
// is armed, and pressing again before the bar line cancels it rather than queueing a
// second one.
~trackLoopToggle = { |t|
    var cps, now, target, wait, tok, on;
    on = case
        { t[\state] == \playing  } { false }
        { t[\state] == \stopped  } { true  }
        { t[\state] == \stopping } { true  }    // pressed twice — change your mind
        { t[\state] == \starting } { false }
        { nil };
    if (on.isNil) {
        (~tlabel.(t) ++ " stop/start ignored — "
            ++ if (t[\state] == \idle) { "nothing recorded yet" } { "mid-take" }).postln;
    } {
        // its own token, NOT ~gen: bumping ~gen here would cancel a pending record
        t[\muteGen] = (t[\muteGen] ? 0) + 1;
        tok    = t[\muteGen];
        cps    = (~cps ? 0.5).max(0.001);
        now    = ~nowCycle.();
        target = now.ceil;
        if (((target - now) / cps) < (s.latency + 0.02)) { target = target + 1 };
        wait   = (target - now) / cps;
        t[\state] = if (on) { \starting } { \stopping };
        (~tlabel.(t) ++ (if (on) { " starting" } { " stopping" })
            ++ " on cycle " ++ target.asInteger
            ++ " (" ++ wait.round(0.01) ++ "s)").postln;
        SystemClock.sched((wait - s.latency).max(0), {
            if (t[\muteGen] == tok) {
                s.makeBundle(s.latency, { t[\synth].set(\playing, on.binaryValue) });
                t[\state] = if (on) { \playing } { \stopped };
                (~tlabel.(t) ++ if (on) { " LOOPING" } { " STOPPED" }).postln;
            };
            nil;
        });
    };
};

// ── Selection: a focus, plus any number of PINNED tracks ────
// The focus is where the stick is. Pins are tracks you have parked in the selection so
// that navigating away does not drop them — so the selection is always
// (pinned tracks) + (the focused one), and there is no mode to be stuck in.
//
// Only tracks can be pinned. The mixer levels are single faders; "record the click"
// has no meaning.
~pinned = ~pinned ? [];

~pinToggle = { |i|
    var k = i ? (~focus ? 0);
    if (~navIsTrack.(k)) {
        // reassign rather than .add — Array.add only mutates in place while capacity
        // allows, so the result has to be taken
        ~pinned = if (~pinned.any { |x| x == k }) {
            ~pinned.select { |x| x != k }
        } {
            ~pinned ++ [k]
        };
        (~tlabel.(~tracks[k]) ++ if (~pinned.any { |x| x == k }) { " PINNED" } { " unpinned" }
            ++ "  selection: " ++ ~selection.().collect({ |x| ~tracks[x][\name] })).postln;
    } {
        ("pin ignored — " ++ ~navName.(k) ++ " is not a track").postln;
    };
    ~pinned;
};

~pinClear = { ~pinned = []; "pins cleared".postln; ~pinned };

// Pins are filtered against the current track count on every read, so a config change
// that shortens ~trackInputs can never leave a pin pointing at a track that is gone.
~selection = {
    var f   = ~focus ? 0;
    var sel = (~pinned ? []).select { |k| k < ~tracks.size };
    if (~navIsTrack.(f) and: { sel.any { |x| x == f }.not }) { sel = sel ++ [f] };
    sel.sort;
};

// Transport acts on the whole selection; the LEVEL deliberately does not. A fader ride
// is a continuous gesture you want to aim at one thing, and ~navAdjust already follows
// the focus.
~selDo = { |what, action|
    var sel = ~selection.();
    if (sel.isEmpty) {
        (what ++ " ignored — the selection is on a mixer level, not a track").postln;
    } {
        sel.do { |k| action.(~tracks[k]) };
    };
    sel;
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
//
// The trigger's own position is kept separately from the scaled result, so that moving
// ~fxDriveMax re-scales what is already there instead of waiting for you to touch R2
// again. Scaling t[x] in place would compound on every change.
~trackFx = { |t, amt|
    t[\fxAmt] = amt.clip(0, 1);
    ~trackFxRescale.(t);
};

~trackFxRescale = { |t|
    t[\fx] = (t[\fxAmt] ? 0) * (~fxDriveMax ? 1.0);
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

// ── Building one track ──────────────────────────────────────
// Three steps, each its own function because they happen at different times:
//   ~allocTrack      buffer + FX bus — once, when the track is created (needs s.sync)
//   ~buildTrackSynth looper + FX synths — at creation AND after every Ctrl+.
//   ~freeTrack       everything — on remove, and on a reload of this file
//
// Buffers are allocated at the length the slowest supported tempo (~minCps) needs, for
// the longest selectable loop, plus room for the overlap tail. Recording then never
// allocates — it only moves \loopFrames — and everything shorter just wraps earlier.
~loopBufFrames = { ~loopFramesFor.(~minCps, ~maxLoopCycles ? ~numLoopCycles) + ~tailFrames.() };

~allocTrack = { |t|
    var maxFrames = ~loopBufFrames.();
    var nch       = t[\inputs].size.clip(1, 2);     // stereo costs twice the buffer
    t[\buf]        = Buffer.alloc(s, maxFrames, nch);
    t[\bufFrames]  = maxFrames;
    t[\cycles]     = t[\cycles] ? ~numLoopCycles;
    t[\headFrames] = ~headFadeFrames.();
    t[\tailFrames] = ~tailFrames.();
    t[\loopFrames] = ~loopFramesFor.(~cps, t[\cycles]).min(maxFrames - t[\tailFrames]);
    // the looper's output always ends up stereo, so the FX bus is stereo either way
    t[\fxBus]      = Bus.audio(s, 2);
    t;
};

// Node ID -> track, for the meter replies. Rebuilt as synths are, so it can never point
// at a track that has been removed.
~meterNodes = ~meterNodes ? IdentityDictionary.new;
~metersOn   = ~metersOn ? false;

~buildTrackSynth = { |t|
    var ins  = t[\inputs];
    var args = [bufnum: t[\buf], loopFrames: t[\loopFrames],
        headFrames: (t[\headFrames] ? 0), tailFrames: (t[\tailFrames] ? 0),
        tailCurve: (~tailCurve ? 0.5), recLevel: 0,
        preLevel: 1, monLevel: ~monLevel, recRun: 0, playing: 0,
        level: t[\level], outBus: t[\fxBus],
        meterRate: if (~metersOn) { ~meterRate ? 0 } { 0 }];
    t[\synth] = if (ins.size >= 2) {
        Synth(\looperStereo, args ++ [inChanL: ins[0], inChanR: ins[1]]);
    } {
        Synth(\looperMono, args ++ [inChan: ins[0]]);
    };
    ~meterNodes[t[\synth].nodeID] = t;
    // addToTail so the FX always runs after every looper. Order among the FX synths
    // themselves is irrelevant — each reads its own private bus.
    t[\fxSynth] = Synth(\trackFx, [
        inBus: t[\fxBus], out: 0, drive: (t[\fx] ? 0),
        tone: ~fxTone, preHighpass: ~fxPreHighpass
    ], addAction: \addToTail);
    t;
};

// sclang's GC never reclaims server-side buffers, so just dropping the reference would
// leak a few MB per track per reload — everything is freed by hand. The generation bump
// comes FIRST: a take still waiting on its bar line would otherwise wake up and .set a
// synth that no longer exists.
~freeTrack = { |t|
    t[\gen]     = (t[\gen] ? 0) + 1;
    t[\muteGen] = (t[\muteGen] ? 0) + 1;
    t[\synth]   !? { |x| ~meterNodes.removeAt(x.nodeID); x.free };
    t[\fxSynth] !? { |x| x.free };
    t[\buf]     !? { |x| x.free };
    t[\fxBus]   !? { |x| x.free };
    t[\synth] = nil; t[\fxSynth] = nil; t[\buf] = nil; t[\fxBus] = nil;
    t[\state] = \idle;
    t;
};

// Build the track synths — and rebuild them after every Ctrl+.
// Ctrl+. sends /g_freeAll, which kills these synths along with everything else. It does
// NOT free buffers, so the recorded audio is still there and the loops can be re-armed.
~buildTracks !? { ServerTree.remove(~buildTracks, s) };   // don't stack on re-eval
~buildTracks = {
    // \overdub means a full loop is already committed to the buffer, so it resumes too;
    // \recording was a half-finished take, so that one just drops to idle.
    var resume = ~tracks.collect { |t|
        #[\playing, \overdub, \starting].includes(t[\state]) and: { t[\buf].notNil }
    };
    // A loop you had stopped keeps its audio but must come back SILENT — panic is not a
    // reason for a muted part to reappear in the mix. It needs no restore: the synths are
    // rebuilt with playing 0 anyway, so only the state has to be put back.
    var silent = ~tracks.collect { |t|
        #[\stopped, \stopping].includes(t[\state]) and: { t[\buf].notNil }
    };
    ~meterNodes.clear;
    ~tracks.do { |t|
        t[\state] = \idle;
        if (t[\buf].notNil and: { t[\fxBus].notNil }) { ~buildTrackSynth.(t) };
    };
    if (~restoreLoopsOnPanic) {
        ~tracks.do { |t, i|
            if (resume[i]) { ~restoreTrack.(t) };
            if (silent[i]) { t[\state] = \stopped };
        };
    };
};
ServerTree.add(~buildTracks, s);

// A server quit/reboot invalidates every buffer, so drop the references. Otherwise the
// ServerTree hook above would fire on the next boot and build synths around dead
// bufnums, flooding the post window until you re-evaluated startup.scd.
~forgetTracks !? { ServerQuit.remove(~forgetTracks, s) };
~forgetTracks = {
    ~meterNodes.clear;
    ~tracks.do { |t|
        t[\buf] = nil; t[\synth] = nil; t[\state] = \idle;
        t[\fxBus] = nil; t[\fxSynth] = nil;
        t[\bufFrames] = nil; t[\loopFrames] = nil;
    };
};
ServerQuit.add(~forgetTracks, s);

// ── The layout: add, remove, re-wire, rename ────────────────
// All of these keep ~trackInputs / ~trackNames in step with ~tracks and mark them
// unsaved, so Save writes the layout you built and a reload of this file rebuilds it.
~syncLayoutVars = {
    ~trackInputs = ~tracks.collect { |t| if (t[\inputs].size >= 2) { t[\inputs].copy } { t[\inputs][0] } };
    ~trackNames  = ~tracks.collect { |t| t[\name] };
    ~settingsMarkDirty !? { ~settingsMarkDirty.(\trackInputs); ~settingsMarkDirty.(\trackNames) };
    ~layoutGen = ~layoutGen + 1;
};

// A jack must exist on the server as configured. Requesting inputs past what the device
// physically has is allowed by scsynth (they are silent), so ~numInputs is the ceiling.
~inputsValid = { |inputs|
    var n = s.options.numInputBusChannels ? ~numInputs ? 2;
    var a = inputs.asArray;
    (a.size >= 1) and: { a.size <= 2 } and: {
        a.every { |i| i.isNumber and: { i >= 0 } and: { i < n } }
    };
};

// Append a track fed by `inputs` (an index, or a pair for stereo). Async: the buffer has
// to exist before the synth reads it, so the strip appears after one server round trip.
// Returns the new track record straight away, its \synth filled in shortly after.
~addTrack = { |inputs, name|
    var ins = inputs.asArray.collect(_.asInteger), t, cap = ~maxTracks ? 12;
    case
    { ~tracks.size >= cap } {
        ("addTrack refused — ~maxTracks is " ++ cap ++ " (config.scd)").warn; nil;
    }
    { ~inputsValid.(ins).not } {
        ("addTrack refused — inputs " ++ ins ++ " must be 1 or 2 indices in 0.."
            ++ ((s.options.numInputBusChannels ? ~numInputs) - 1)).warn; nil;
    }
    {
        t = ~newTrack.(ins, name, ~tracks.size);
        ~tracks = ~tracks ++ [t];
        ~syncLayoutVars.();
        fork {
            ~allocTrack.(t);
            s.sync;
            // still there? it can be removed before the buffer lands
            if (~tracks.any { |x| x === t }) {
                ~buildTrackSynth.(t);
                (~tlabel.(t) ++ " ADDED — in " ++ ~inLabel.(t)).postln;
            } {
                ~freeTrack.(t);
            };
        };
        t;
    };
};

// Remove a track and renumber the ones after it. The focus and the pins move with the
// tracks they were on: a pin on t5 is a pin on the same audio after t2 goes, so it
// becomes t4. The focus, if it was on the removed track, lands on whatever slid into
// its slot — the next track, or the mixer if it was the last one.
~removeTrack = { |i|
    var t = ~tracks[i], f = ~focus ? 0;
    if (t.isNil) {
        ("removeTrack: no track " ++ i).warn; nil;
    } {
        ~freeTrack.(t);
        ~tracks = ~tracks.reject { |x| x === t };
        ~tracks.do { |x, k| x[\idx] = k };
        ~pinned = (~pinned ? []).reject({ |k| k == i }).collect { |k| if (k > i) { k - 1 } { k } };
        if (f > i) { ~focus = f - 1 } { ~focus = f.clip(0, ~navSize.() - 1) };
        ~syncLayoutVars.();
        (~tlabel.(t) ++ " REMOVED — " ++ ~tracks.size ++ " tracks").postln;
        t;
    };
};

// Feed a track from a different jack. Same width (mono->mono, pair->pair) is a .set on
// the running synth: the loop keeps playing, and an overdub in progress keeps going on
// the new signal. Changing WIDTH rebuilds the buffer, because BufRd/BufWr channel counts
// are fixed when the SynthDef is built — that clears the loop, and the post window says
// so before it happens.
~setTrackInput = { |i, inputs|
    var t = ~tracks[i], ins = inputs.asArray.collect(_.asInteger);
    case
    { t.isNil } { ("setTrackInput: no track " ++ i).warn; nil }
    { ~inputsValid.(ins).not } {
        ("setTrackInput refused — inputs " ++ ins ++ " must be 1 or 2 indices in 0.."
            ++ ((s.options.numInputBusChannels ? ~numInputs) - 1)).warn; nil;
    }
    { ins == t[\inputs] } { t }
    { ins.size == t[\inputs].size } {
        t[\inputs] = ins;
        t[\synth] !? { |x|
            if (ins.size >= 2) { x.set(\inChanL, ins[0], \inChanR, ins[1]) } { x.set(\inChan, ins[0]) };
        };
        ~syncLayoutVars.();
        (~tlabel.(t) ++ " now on in " ++ ~inLabel.(t)).postln;
        t;
    }
    {
        if (t[\state] != \idle) {
            (~tlabel.(t) ++ " mono<->stereo change — the loop is cleared").postln;
        };
        ~freeTrack.(t);
        t[\inputs] = ins;
        ~syncLayoutVars.();
        fork {
            ~allocTrack.(t);
            s.sync;
            if (~tracks.any { |x| x === t }) { ~buildTrackSynth.(t) } { ~freeTrack.(t) };
            (~tlabel.(t) ++ " rebuilt " ++ if (ins.size >= 2) { "stereo" } { "mono" }
                ++ " on in " ++ ~inLabel.(t)).postln;
        };
        t;
    };
};

~renameTrack = { |i, name|
    var t = ~tracks[i];
    if (t.isNil) { ("renameTrack: no track " ++ i).warn; nil } {
        t[\name] = name.asString.stripWhiteSpace;
        if (t[\name].isEmpty) { t[\name] = "Track " ++ i };
        ~syncLayoutVars.();
        t;
    };
};

// Throw the session's tracks away and build the layout ~trackInputs / ~trackNames
// describe. This is what loading the file does, and what "reload from file" does when
// the file's layout differs from the session's. Loops do not survive it — a reload is an
// authoring action, not a performance one; Ctrl+. is the live one and keeps them.
~rebuildTracks = {
    ~tracks.do { |t| ~freeTrack.(t) };
    ~tracks = ~trackInputs.collect { |spec, i|
        ~newTrack.(spec, ~trackNames !? { ~trackNames[i] }, i)
    };
    ~pinned = (~pinned ? []).select { |k| k < ~tracks.size };
    ~focus  = (~focus ? 0).clip(0, ~navSize.() - 1);
    ~layoutGen = ~layoutGen + 1;
    // s.sync waits for the SynthDef and then for the buffers to actually exist, rather
    // than assuming they will by some fixed delay.
    fork {
        var maxFrames, mb, chans = 0, nIn;
        s.sync;
        ~tracks.do { |t| ~allocTrack.(t); chans = chans + t[\inputs].size.clip(1, 2) };
        s.sync;
        ~buildTracks.value;
        maxFrames = ~loopBufFrames.();
        mb = (maxFrames * 4 * chans / 1e6).round(0.1);
        ("Multitrack ready: " ++ ~tracks.size ++ " tracks ("
            ++ ~tracks.collect({ |t| t[\name] ++ "=" ++ ~inLabel.(t) }).join(", ") ++ ")"
            ++ " | " ++ (maxFrames / (s.sampleRate ? 44100)).round(0.1) ++ "s max loop, "
            ++ mb ++ " MB total").postln;
        // A layout written for one interface, booted on another with fewer inputs: the
        // track still builds (an index past the inputs reads an ordinary silent bus), but
        // say so, because "no signal" would otherwise look like a cable problem.
        nIn = s.options.numInputBusChannels ? ~numInputs ? 2;
        ~tracks.do { |t|
            if (t[\inputs].any { |i| i >= nIn }) {
                (~tlabel.(t) ++ " input " ++ ~inLabel.(t) ++ " is beyond the " ++ nIn
                    ++ " inputs this device was booted with — silent until re-wired").warn;
            };
        };
    };
};
~rebuildTracks.();

// ── Meters ──────────────────────────────────────────────────
// The synths report in only while a dashboard is subscribed (dashboard.scd keeps
// ~metersOn alive from the browser's heartbeat). Turning it on is a .set of the reply
// rate on every synth; off is rate 0, which stops the Impulse dead.
OSCdef(\trkMeter, { |msg|
    ~meterNodes[msg[1]] !? { |t| t[\inAmp] = msg[3]; t[\outAmp] = msg[4] };
}, '/trkMeter').fix;

~setMeters = { |on|
    var rate = if (on) { ~meterRate ? 0 } { 0 };
    ~metersOn = on and: { rate > 0 };
    ~tracks.do { |t| t[\synth] !? { |x| x.set(\meterRate, rate) } };
    if (~metersOn.not) { ~tracks.do { |t| t[\inAmp] = 0; t[\outAmp] = 0 } };
    ~metersOn;
};

// ── MIDI ────────────────────────────────────────────────────
// There is none, deliberately. The MPK mini map was removed: everything is driven from
// the DualSense or the mouse. One control surface with one obvious mapping beats two
// that can disagree about which track is selected — and the MPK's pads sat on channel 0
// alongside its keyboard, which was a standing trap.
//
// MIDIdefs installed with .fix survive both Ctrl+. and a file reload, so a session that
// had ever run the old map would keep firing it. Free them by key; a no-op on a fresh
// boot, and the only way to make reloading this file actually remove the mapping.
[\midiPrint, \midiCcPrint, \looperPads, \looperKnobs, \looperPedal].do { |k|
    MIDIdef.all[k] !? { |d| d.free };
};

("=== looper.scd loaded — " ++ ~trackInputs.size ++ " tracks ===").postln;
