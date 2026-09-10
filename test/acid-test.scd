// ============================================================
//  LIVE LOOPER · acid-test.scd
//  The synths acid.tidal needs: sawtooth, supersaw, and the sidechain ducker.
//
//  MEASURING BRIGHTNESS
//  The obvious metric — mean sample-to-sample change over level — is WRONG here, and
//  quietly so. Filtering a saw toward a sine makes it smoother per sample but the
//  normalised figure goes UP, so a 100 Hz cutoff and a 6 kHz cutoff came out 1.36x
//  apart and a working sweep looked flat. This records the signal twice, once raw and
//  once through a high-pass, and compares their levels: an actual spectral measure.
//
//  Every swept reading is judged against FIXED-cutoff references recorded in the same
//  run, so the test cannot pass by accident on an absolute threshold that happens to
//  suit one machine.
//
//  Run it headless (no ZOOM H8 needed):
//    & "C:\Program Files\SuperCollider-3.14.1\sclang.exe" -D d:/livelooper/test/acid-test.scd
//
//  Expect: "37 passed, 0 failed".
// ============================================================
(
var pass = 0, fail = 0, ok, report, open, shut, swept, flat, ducked;

ok = { |label, cond|
    if (cond) { pass = pass + 1; ("  PASS  " ++ label).postln }
             { fail = fail + 1; ("  FAIL  " ++ label).postln };
};

s = Server(\llAcidTest, NetAddr("127.0.0.1", 57167));
Server.default = s;
s.options.device = nil;
s.options.numInputBusChannels  = 2;
s.options.numOutputBusChannels = 2;
s.options.memSize = 8192 * 16;

s.waitForBoot({
    fork {
        1.0.wait;
        "D:/livelooper/config.scd".load;
        ~dirtPort = NetAddr.langPort;
        ~dirt = SuperDirt(2, s); ~dirt.start(~dirtPort, [0, 0, 0, 0]);
        2.0.wait;
        // Load it the way a PERSON does: evaluated from the editor, at TOP LEVEL, not
        // from inside a Routine. This matters more than it looks. The first version of
        // this test loaded acid.scd inside this very fork, which handed the file a
        // Routine it would never have in real use — so a top-level s.sync sailed through
        // here and threw "yield was called outside of a Routine" for the user, taking
        // the entire ducking section down silently while the synths still loaded.
        // AppClock runs a plain function, so thisThread is not a Routine: same as the IDE.
        ~acidLoad = nil;
        AppClock.sched(0, {
            try { "D:/livelooper/acid.scd".load; ~acidLoad = \ok }
                { |e| ~acidLoad = e.errorString };
            nil;
        });
        while { ~acidLoad.isNil } { 0.1.wait };

        "".postln; "--- IT LOADS THE WAY IT IS ACTUALLY LOADED ---".postln;
        if (~acidLoad != \ok) { ("        (" ++ ~acidLoad ++ ")").postln };
        ok.("loads at top level, outside a Routine", ~acidLoad == \ok);
        // its own fork still has to finish before anything below is true
        while { ~duckSynths.isNil } { 0.2.wait };
        2.0.wait;

        "".postln; "--- THE SYNTHS EXIST ---".postln;
        [\sawtooth, \supersaw, \duckGlobal, \duckTrigger].do { |k|
            ok.(k.asString ++ " built", SynthDescLib.global.at(k).notNil);
        };
        // SuperDirt forwards unrecognised params to the SynthDef BY NAME, so every name
        // acid.tidal sends has to be a real argument here or it silently does nothing.
        [\lpbase, \lpenv, \lpa, \lpd, \lps, \lpr, \lpq].do { |k|
            ok.("sawtooth accepts " ++ k,
                SynthDescLib.global.at(\sawtooth).controlNames.includes(k));
        };
        ok.("supersaw accepts spread",
            SynthDescLib.global.at(\supersaw).controlNames.includes(\spread));
        // cutoff must NOT be an argument: sending it would make SuperDirt insert its own
        // static dirt_lpf in series with the envelope below.
        ok.("sawtooth does NOT take cutoff",
            SynthDescLib.global.at(\sawtooth).controlNames.includes(\cutoff).not);

        "".postln; "--- BRIGHTNESS, MEASURED SPECTRALLY ---".postln;
        ~probe = Bus.audio(s, 2);
        // raw into one buffer, high-passed into another, same signal same instant
        SynthDef(\grab2, { |bufRaw, bufHi, in|
            var sig = In.ar(in, 2).sum;
            RecordBuf.ar(sig, bufRaw, loop: 0);
            RecordBuf.ar(HPF.ar(HPF.ar(sig, 1200), 1200), bufHi, loop: 0, doneAction: 2);
        }).add;
        s.sync;

        report = { |label, args|
            var raw = Buffer.alloc(s, (s.sampleRate * 0.5).asInteger, 1);
            var hi  = Buffer.alloc(s, (s.sampleRate * 0.5).asInteger, 1);
            var out = nil, rawA = nil, hiA = nil;
            var rms = { |a, from, to|
                var sl = a.copyRange((from * s.sampleRate).asInteger,
                    (to * s.sampleRate).asInteger - 1);
                (sl.squared.sum / sl.size).sqrt;
            };
            s.sync;
            Synth(\grab2, [bufRaw: raw, bufHi: hi, in: ~probe.index],
                addAction: \addToTail);
            Synth(\sawtooth, [out: ~probe.index, freq: 110, sustain: 0.4] ++ args,
                addAction: \addToHead);
            0.7.wait;
            raw.loadToFloatArray(0, raw.numFrames, { |a| rawA = a });
            hi.loadToFloatArray(0, hi.numFrames, { |a| hiA = a });
            while { rawA.isNil or: { hiA.isNil } } { 0.05.wait };
            raw.free; hi.free;
            // fraction of the energy sitting above 1.2 kHz, in two slices of the note
            out = [
                rms.(hiA, 0.005, 0.035) / rms.(rawA, 0.005, 0.035).max(1e-6),
                rms.(hiA, 0.20,  0.30)  / rms.(rawA, 0.20,  0.30).max(1e-6)
            ];
            (label ++ "  head " ++ out[0].round(0.0001)
                ++ "   tail " ++ out[1].round(0.0001)).postln;
            out;
        };

        // Fixed references first. If these two do not separate, nothing below means
        // anything — so this is asserted, not assumed.
        shut = report.("  fixed  100 Hz        ", [lpbase: 100,  lpenv: 0, lpq: 0.05]);
        open = report.("  fixed 6000 Hz        ", [lpbase: 6000, lpenv: 0, lpq: 0.05]);
        ("        (the metric separates them by "
            ++ (open[0] / shut[0].max(1e-6)).round(0.1) ++ "x)").postln;
        ok.("the metric can tell 100 Hz from 6 kHz",
            (open[0] / shut[0].max(1e-6)) > 5);
        ok.("a closed filter really is dark", shut[0] < 0.05);

        "".postln; "--- THE ENVELOPE SWEEPS ---".postln;
        swept = report.("  swept 100 Hz +5.9oct ",
            [lpbase: 100, lpenv: 5.9, lpa: 0.005, lpd: 0.12, lps: 0.2, lpr: 0.05,
                lpq: 0.05]);
        ("        (head is " ++ (swept[0] / open[0].max(1e-6)).round(0.01)
            ++ "x the OPEN reference; tail is "
            ++ (swept[1] / shut[0].max(1e-6)).round(0.01)
            ++ "x the SHUT one)").postln;
        ok.("the attack is as open as a 6 kHz filter",
            (swept[0] / open[0].max(1e-6)) > 0.5);
        ok.("...and the note closes down again",
            (swept[0] / swept[1].max(1e-6)) > 4);
        ok.("the sustain settles near the base, not at it",
            swept[1] < (open[0] * 0.3));

        flat = report.("  no envelope          ", [lpbase: 100, lpenv: 0, lpq: 0.05]);
        ok.("lpenv 0 does not sweep at all",
            (flat[0] / flat[1].max(1e-6)).inclusivelyBetween(0.5, 2.0));

        "".postln; "--- THE SUB KICK CARRIES LOW END ---".postln;
        // The point of the layer is energy below 80 Hz. Measure it the same way the
        // brightness test does, but at the other end of the spectrum: record the signal
        // raw and low-passed at once, and compare.
        ok.("subkick built", SynthDescLib.global.at(\subkick).notNil);
        [\subfreq, \subdrop, \subtime, \subdecay, \subdrive].do { |k|
            ok.("subkick accepts " ++ k,
                SynthDescLib.global.at(\subkick).controlNames.includes(k));
        };
        SynthDef(\grabLow, { |bufRaw, bufLo, in|
            var sig = In.ar(in, 2).sum;
            RecordBuf.ar(sig, bufRaw, loop: 0);
            RecordBuf.ar(LPF.ar(LPF.ar(sig, 80), 80), bufLo, loop: 0, doneAction: 2);
        }).add;
        s.sync;

        ~lowOf = { |synthName, args|
            var raw = Buffer.alloc(s, (s.sampleRate * 0.8).asInteger, 1);
            var lo  = Buffer.alloc(s, (s.sampleRate * 0.8).asInteger, 1);
            var rawA = nil, loA = nil, out;
            var rms = { |a| (a.squared.sum / a.size).sqrt };
            s.sync;
            Synth(\grabLow, [bufRaw: raw, bufLo: lo, in: ~probe.index],
                addAction: \addToTail);
            Synth(synthName, [out: ~probe.index, sustain: 0.5] ++ args,
                addAction: \addToHead);
            1.0.wait;
            raw.loadToFloatArray(0, raw.numFrames, { |a| rawA = a });
            lo.loadToFloatArray(0, lo.numFrames, { |a| loA = a });
            while { rawA.isNil or: { loA.isNil } } { 0.05.wait };
            raw.free; lo.free;
            // how much of the total energy is under 80 Hz, and how long it lasts
            out = [ rms.(loA) / rms.(rawA).max(1e-9), rms.(loA) ];
            out;
        };

        ~sub  = ~lowOf.(\subkick, [subfreq: 50, subdrop: 1.6, subtime: 0.04,
            subdecay: 0.32, subdrive: 1.5, subclick: 0.06]);
        ~lead = ~lowOf.(\sawtooth, [freq: 43.midicps, lpbase: 100, lpenv: 5.7,
            lps: 0.2, lpd: 0.12, lpq: 0.3]);
        ("        (subkick: " ++ (~sub[0] * 100).round(0.1)
            ++ "% of its energy under 80 Hz)").postln;
        ("        (the 98 Hz saw, for scale: " ++ (~lead[0] * 100).round(0.1)
            ++ "%)").postln;
        ok.("most of the subkick IS sub",  ~sub[0] > 0.7);
        ok.("and there is real level down there", ~sub[1] > 0.02);
        // the pitch drop has to actually drop, or it is a hum not a kick
        ~flatSub = ~lowOf.(\subkick, [subfreq: 50, subdrop: 0, subtime: 0.04,
            subdecay: 0.32, subdrive: 1.5, subclick: 0]);
        ok.("subdrop 0 is a different sound from subdrop 1.6",
            (~sub[1] - ~flatSub[1]).abs > (~flatSub[1] * 0.02));

        "".postln; "--- DUCKING ---".postln;
        ok.("duck is registered as a module",
            ~dirt.modules.any { |m| m.name == 'duck' });
        ok.("one control bus per orbit",
            ~duckBus.notNil and: { ~duckBus[0].notNil });
        ok.("one ducker synth per orbit",
            ~duckSynths.notNil and: { ~duckSynths.size == ~dirt.orbits.size });
        ducked = ~duckBus[0].getSynchronous;
        ok.("the bus rests at unity gain", (ducked - 1).abs < 0.001);

        "".postln; "--- DUCK THROUGH A REAL EVENT ---".postln;
        // THIS is the test that matters, and its absence cost a working feature.
        // The checks above all passed while ducking was completely broken: the module
        // body runs inside DirtEvent`s `event.use { }`, so its ~duckBus resolved against
        // the EVENT`s environment and came back nil, throwing on every single event.
        // Firing \duckTrigger by hand never touched that path. Only a real /dirt/play
        // message does.
        //
        // Sampled repeatedly rather than once: SuperDirt bundles the trigger with its
        // own latency, so the dip lands some tenths of a second after the message and a
        // single well-timed read would be luck.
        ~minOf = { |bus, secs|
            var lo = 2, t = 0;
            while { t < secs } { lo = lo.min(bus.getSynchronous); 0.02.wait; t = t + 0.02 };
            lo;
        };
        ~duckBus[0].set(1); ~duckBus[1].set(1); ~duckBus[2].set(1);
        0.3.wait;
        NetAddr("127.0.0.1", ~dirtPort).sendMsg('/dirt/play',
            "_id_", 1, "cps", 0.5, "cycle", 0.0, "delta", 0.5,
            "s", "sawtooth", "orbit", 0, "sustain", 0.2, "freq", 110,
            "duck", "1:2", "duckdepth", 0.8, "duckattack", 0.4);
        ~e1 = ~minOf.(~duckBus[1], 1.2);
        ~e2 = ~duckBus[2].getSynchronous;
        ~e0 = ~duckBus[0].getSynchronous;
        ("        (targeted orbit 1 fell to " ++ ~e1.round(0.001) ++ ")").postln;
        ok.("a real event ducks the orbits it names", ~e1 < 0.5);
        ok.("...and both of them",  ~e2 < 1.0);
        // orbit 0 was not named, so it must be untouched
        ("        (untargeted orbit 0 sat at " ++ ~e0.round(0.001) ++ ")").postln;
        ok.("orbits it does not name are untouched", (~e0 - 1).abs < 0.05);
        1.0.wait;
        ok.("everything returns to unity",
            (~duckBus[1].getSynchronous - 1).abs < 0.05);

        "".postln;
        ("======== " ++ pass ++ " passed, " ++ fail ++ " failed ========").postln;
        0.5.wait;
        0.exit;
    };
});
)
