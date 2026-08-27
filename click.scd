// ============================================================
//  LIVE LOOPER  ·  click.scd
//  Tempo-locked metronome, generated in SC, RIGHT channel only.
//  Loaded by startup.scd after looper.scd.
//
//  L/R HACK: the click is written to bus 1 (RIGHT) only. Feed the PA from the
//  H8 Line Out LEFT channel (mono cable, tip = left) so the audience never hears
//  the click; you monitor headphones (both channels) and hear it on the right.
// ============================================================

// ── Settings come from config.scd ───────────────────────────
// (~clickDiv, ~clickAmp, ~clickOffset)
// ~clickOffset is read LIVE on every beat, so you can tweak it in the interpreter and
// hear it immediately — bigger = click later. Write the value you land on back to config.
~clickDiv ?? {
    Error("click.scd: config.scd has not been loaded. Evaluate startup.scd instead.").throw
};

// ── Runtime state (not config — survives a reload) ──────────
~clickOn = ~clickOn ? false;      // start muted — dashboard or OPTIONS toggles it

// ── Click sound ─────────────────────────────────────────────
// accent = 1 on the cycle downbeat (higher + louder). RIGHT channel only.
SynthDef(\click, { |accent = 0, amp = 0.5|
    var freq = Select.kr(accent, [1000, 1600]);
    var env  = EnvGen.kr(Env.perc(0.001, 0.04), doneAction: 2);
    var sig  = SinOsc.ar(freq, 0, env * amp * Select.kr(accent, [0.7, 1.0]));
    Out.ar(1, sig);   // bus 1 = RIGHT only (private click)
}).add;

// ── Beat scheduler ──────────────────────────────────────────
// Re-derives the beat grid's TIMING from the OSC clock each iteration (so it can't
// drift), but keeps nextBeat strictly MONOTONIC so a beat is never fired twice —
// that double-fire was the "flam". ~clickGen makes any stale scheduler from an
// earlier evaluation self-terminate, so re-loading can't stack up loops.
// PANIC SURVIVAL — Ctrl+. calls SystemClock.clear before anything else, which cancels
// this Task's next wakeup and silently stops the click for good. So the scheduler lives
// in a function that CmdPeriod can call again. CmdPeriod runs its hooks AFTER clearing
// the clocks, so re-playing here sticks.
~startClickTask !? { CmdPeriod.remove(~startClickTask) };   // don't stack on re-eval
~startClickTask = {
    ~clickGen = (~clickGen ? 0) + 1;
    ~clickRoutine !? { ~clickRoutine.stop };   // kill old Routine-based version if present
    ~clickTask   !? { ~clickTask.stop };
    ~clickTask = Task({
        var myGen = ~clickGen;
        var cps, div, cyclePos, beatPos, nextBeat, dt, target, lead;
        cps      = (~cps ? 0.5).max(0.001);
        div      = (~clickDiv ? 4).max(1);
        cyclePos = (~lastCycle ? 0) + ((Main.elapsedTime - (~lastEventTime ? Main.elapsedTime)) * cps);
        nextBeat = (cyclePos * div).ceil;      // first beat at/after now
        while({ myGen == ~clickGen }, {        // self-terminate if a newer load happened
            cps      = (~cps ? 0.5).max(0.001);
            div      = (~clickDiv ? 4).max(1);
            cyclePos = (~lastCycle ? 0) + ((Main.elapsedTime - (~lastEventTime ? Main.elapsedTime)) * cps);
            beatPos  = cyclePos * div;
            // if we've fallen behind (tempo jump / GC pause), catch up without a burst
            if ((beatPos - nextBeat) > 0.25) { nextBeat = beatPos.ceil };
            dt = (nextBeat - beatPos) / (cps * div);
            // `target` is how long until the click should SOUND. Give the server as much
            // lead as we actually have (capped at s.latency) and timestamp the bundle for
            // the remainder, so the click lands ON the beat rather than s.latency after
            // it. Taking the min also means a click interval shorter than s.latency still
            // works — it just gets less lead — instead of firing late or spinning.
            // With the grid anchored to when events sound, the ideal ~clickOffset is 0.
            target = dt + ~clickOffset;
            lead   = target.clip(0, s.latency);
            (target - lead).max(0).wait;
            if (~clickOn and: { myGen == ~clickGen }) {
                s.makeBundle(lead, {
                    Synth(\click, [\accent, (nextBeat % div == 0).asInteger, \amp, ~clickAmp]);
                });
            };
            nextBeat = nextBeat + 1;           // strictly monotonic — never repeat a beat
        });
    }).play(SystemClock);
};
CmdPeriod.add(~startClickTask);
~startClickTask.();

// ── No MIDI ─────────────────────────────────────────────────
// The click is toggled from the dashboard button or OPTIONS on the DualSense. The MPK
// pedal responder is gone; .fix kept it alive through Ctrl+. and through a reload, so
// free it by key or a session that once had it would keep toggling the click.
MIDIdef.all[\clickPedal] !? { |d| d.free };

"=== click.scd loaded — OPTIONS / dashboard toggles | ~clickDiv=4 | RIGHT channel ===".postln;
