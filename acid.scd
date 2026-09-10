// ============================================================
//  LIVE LOOPER  ·  acid.scd
//  SynthDefs for acid.tidal — a sawtooth and a supersaw with their OWN filter
//  envelope, plus a sidechain ducker.
//
//  WHY THIS FILE EXISTS
//  Strudel is a Web Audio engine and ships oscillators and a filter ADSR built in.
//  SuperDirt does not: it plays samples, and its low-pass module (dirt_lpf) has exactly
//  two controls, cutoff and resonance, with no envelope at all. So `s("sawtooth")` and
//  `.lpenv()` have nothing to land on until these exist.
//
//  Load it AFTER startup.scd:
//      "D:/livelooper/acid.scd".load;
//  Re-evaluating is safe — SynthDefs are replaced by name.
//
//  ── THE FILTER ENVELOPE ─────────────────────────────────────
//  Follows Strudel's shape so the numbers from the original patch transfer directly:
//
//      cutoff(t) = lpbase * 2 ** (lpenv * adsr(t))
//
//  lpenv is therefore in OCTAVES, not Hz — which is why 100 Hz and lpenv 5.9 gives a
//  sweep up to ~6 kHz rather than to 106 Hz. lps is a fraction of that depth, so
//  lps 0.2 with lpenv 5.9 settles at 100 * 2**1.18 = ~226 Hz.
//
//  ── WHY NOT `cutoff` ────────────────────────────────────────
//  Because SuperDirt inserts its own filter the moment `cutoff` is present:
//      ~dirt.addModule('lpf', { ... }, { ~cutoff.notNil });
//  Sending cutoff would run dirt_lpf IN SERIES with the envelope below — two filters,
//  one of them static, and a sound noticeably duller than intended. `lpbase` keeps the
//  two apart, so `# cutoff` remains free for its normal job if you ever want it.
// ============================================================

(
// The envelope, shared by both synths so they cannot drift apart.
// Attack is a hair above zero by default: a literal 0 makes the filter step rather than
// open, which reads as a click on every note at high resonance.
// Written as an explicit fixed-length envelope rather than Env.adsr + a gate. A gated
// ADSR needs something to close the gate, and the note's own length is the only thing
// that would — which made lpr silently dead. Here the hold segment is whatever the note
// has left after attack and decay, so release always happens and lpr always means
// something.
~acidFilterEnv = { |sig, sustain, lpbase, lpenv, lpa, lpd, lps, lpr, lpq|
    var hold = (sustain - lpa - lpd - lpr).max(0);
    var env  = EnvGen.kr(Env(
        [0, 1, lps, lps, 0],
        [lpa, lpd, hold, lpr],
        curve: -4
    ));
    var cutoff = (lpbase * (2 ** (lpenv * env))).clip(20, SampleRate.ir * 0.45);
    RLPF.ar(sig, cutoff, lpq.linexp(0, 1, 1, 0.02));
};

// A plain saw. `accelerate` and `sustain` behave the way they do everywhere else in
// SuperDirt, so this drops into a normal Tidal pattern without special handling.
SynthDef(\sawtooth, { |out, sustain = 1, freq = 440, pan = 0, accelerate = 0,
        begin = 0, end = 1, speed = 1, offset = 0,
        lpbase = 100, lpenv = 0, lpa = 0.005, lpd = 0.12, lps = 0.2, lpr = 0.1, lpq = 0.3|
    var rate = freq * (2 ** (Sweep.kr(1, accelerate) / 12));
    var amp  = AmpCompA.kr(freq);
    var env  = EnvGen.ar(Env.linen(0.002, sustain, 0.02, 1, -3), doneAction: 2);
    var sig  = Saw.ar(rate);
    sig = ~acidFilterEnv.(sig, sustain, lpbase, lpenv, lpa, lpd, lps, lpr, lpq);
    Out.ar(out, DirtPan.ar(sig * amp, ~dirt.numChannels, pan, env));
}).add;

// Seven detuned saws. `spread` is in cents at the extremes; the middle voice stays
// exactly on pitch so the chord's root is not smeared.
SynthDef(\supersaw, { |out, sustain = 1, freq = 440, pan = 0, accelerate = 0,
        begin = 0, end = 1, speed = 1, offset = 0,
        lpbase = 100, lpenv = 0, lpa = 0.005, lpd = 0.12, lps = 0.2, lpr = 0.1, lpq = 0.3,
        spread = 18, voices = 7|
    var rate    = freq * (2 ** (Sweep.kr(1, accelerate) / 12));
    var amp     = AmpCompA.kr(freq);
    var env     = EnvGen.ar(Env.linen(0.002, sustain, 0.02, 1, -3), doneAction: 2);
    var detune  = Array.fill(7, { |i| (i - 3) / 3 });          // -1 .. 0 .. 1
    var sig     = Mix(Saw.ar(rate * (2 ** (detune * spread / 1200)),
        // the detuned voices sit lower than the centre one, so the pitch stays legible
        Array.fill(7, { |i| if (i == 3) { 0.5 } { 0.28 } })));
    sig = ~acidFilterEnv.(sig, sustain, lpbase, lpenv, lpa, lpd, lps, lpr, lpq);
    Out.ar(out, DirtPan.ar(sig * amp, ~dirt.numChannels, pan, env));
}).add;
);

// ── Sub kick ────────────────────────────────────────────────
// A kick sample carries the attack; this carries the weight. Layering the two is how
// nearly every produced kick gets its depth — one sample rarely has both a click that
// cuts and a body that lasts.
//
// The pitch drop is the whole trick: starting an octave or two up and falling to the
// target in ~40 ms reads as the "thump" of a beater, and gives the ear a transient to
// latch onto. Held at a fixed low pitch it just sounds like a hum.
//
// subdrive matters more than it looks on small speakers. Saturating a 50 Hz sine adds
// harmonics at 100, 150, 200 Hz; a laptop speaker that cannot reproduce 50 Hz at all
// still reproduces those, and the ear infers the missing fundamental. So the kick reads
// as deep on a system that is physically incapable of playing the note.
(
SynthDef(\subkick, { |out, sustain = 1, pan = 0,
        subfreq = 50, subdrop = 1.6, subtime = 0.04, subdecay = 0.32, subdrive = 1.5,
        subclick = 0.06|
    // falls subdrop octaves onto subfreq; curve -6 makes almost all of it happen early
    var pitch = EnvGen.kr(Env([subdrop, 0], [subtime], curve: -6));
    var amp   = EnvGen.ar(Env.perc(0.001, subdecay, 1, -4), doneAction: 2);
    var sig   = SinOsc.ar(subfreq * (2 ** pitch));
    // a short noise tick, so the kick still locates itself on a small speaker
    var tick  = HPF.ar(WhiteNoise.ar, 1200)
        * EnvGen.ar(Env.perc(0.0005, 0.012)) * subclick;
    sig = (sig * subdrive).tanh / subdrive.max(1).sqrt;
    Out.ar(out, DirtPan.ar((sig * amp) + tick, ~dirt.numChannels, pan, 1));
}).add;
);

// ── Sidechain ducking ───────────────────────────────────────
// Strudel's .duck("3:4:5:6") ducks those orbits from the pattern carrying it. SuperDirt
// has no such thing, so this builds one: a control bus per orbit that the kick writes a
// dip into, and a global effect on each ducked orbit that reads it.
//
// Global rather than per-event on purpose — a duck has to apply to whatever is already
// sounding on that orbit, which an event-triggered synth cannot do.
//
// Everything below runs inside `fork`. It has to: creating a Synth from a SynthDef you
// just added needs s.sync first, and s.sync yields — which only a Routine can do. At
// top level, which is how this file is actually loaded, an unwrapped s.sync throws
// "yield was called outside of a Routine" and takes the whole ducking section down
// with it, silently, while the synths above still load fine.
(
fork {
~dirt ?? {
    Error("acid.scd: SuperDirt is not running. Evaluate startup.scd first.").throw
};
~duckBus ?? { ~duckBus = () };
~dirt.orbits.do { |orbit, i|
    ~duckBus[i] ?? { ~duckBus[i] = Bus.control(s, 1) };
    ~duckBus[i].set(1);
};

// Reads its orbit's bus and applies it as gain. Sits at the tail of the orbit's chain.
SynthDef(\duckGlobal, { |out, duckbus|
    var sig = In.ar(out, ~dirt.numChannels);
    ReplaceOut.ar(out, sig * In.kr(duckbus, 1).lag(0.005));
}).add;

// Fired by the ducking source (the kick). `duckdepth` is how far down it pulls,
// `duckattack` how long it takes to come back — matching Strudel's names.
SynthDef(\duckTrigger, { |sustain = 1, duckdepth = 0.8, duckattack = 0.16, duckbus|
    var dip = EnvGen.kr(
        Env([1 - duckdepth, 1 - duckdepth, 1], [0.005, duckattack], curve: 2),
        doneAction: 2
    );
    Out.kr(duckbus, dip);
}).add;

s.sync;

// The receiving side: one always-on ducker per orbit.
~duckSynths !? { ~duckSynths.do(_.free) };
~duckSynths = ~dirt.orbits.collect { |orbit, i|
    Synth(\duckGlobal, [out: orbit.outBus, duckbus: ~duckBus[i]],
        orbit.globalEffects.last.synth, \addAfter);
};

// The sending side. `duck` takes the orbits to duck, as a Tidal-style "3:4:5:6" string
// or a list. Registered as a SuperDirt module so it fires from a pattern.
~dirt.addModule('duck', { |dirtEvent|
    var targets = ~duck.asString.split($:).collect { |x| x.asInteger };
    targets.do { |orbitIndex|
        ~duckBus[orbitIndex] !? { |bus|
            Synth(\duckTrigger, [
                sustain: ~sustain, duckdepth: (~duckdepth ? 0.8),
                duckattack: (~duckattack ? 0.16), duckbus: bus.index
            ], s.defaultGroup, \addToHead);
        };
    };
}, { ~duck.notNil });

// Inside the fork, so it prints when the duckers are genuinely up rather than when the
// file finished being read.
("=== acid.scd loaded — synths: sawtooth, supersaw | duck on "
    ++ ~duckSynths.size ++ " orbits ===").postln;
};
);
