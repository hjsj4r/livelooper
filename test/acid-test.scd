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
//  Expect: "26 passed, 0 failed".
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

        "".postln; "--- DUCKING ---".postln;
        ok.("duck is registered as a module",
            ~dirt.modules.any { |m| m.name == 'duck' });
        ok.("one control bus per orbit",
            ~duckBus.notNil and: { ~duckBus[0].notNil });
        ok.("one ducker synth per orbit",
            ~duckSynths.notNil and: { ~duckSynths.size == ~dirt.orbits.size });
        // the bus sits at unity until something ducks it
        ducked = ~duckBus[0].getSynchronous;
        ok.("the bus rests at unity gain", (ducked - 1).abs < 0.001);
        // fire a duck and catch the dip while it is happening
        Synth(\duckTrigger, [sustain: 0.5, duckdepth: 0.8, duckattack: 0.3,
            duckbus: ~duckBus[0].index]);
        0.05.wait;
        ducked = ~duckBus[0].getSynchronous;
        ("        (gain during the duck: " ++ ducked.round(0.001) ++ ")").postln;
        ok.("a trigger pulls the gain down", ducked < 0.5);
        0.5.wait;
        ducked = ~duckBus[0].getSynchronous;
        ("        (gain after it recovers: " ++ ducked.round(0.001) ++ ")").postln;
        ok.("and it comes back to unity", (ducked - 1).abs < 0.05);

        "".postln;
        ("======== " ++ pass ++ " passed, " ++ fail ++ " failed ========").postln;
        0.5.wait;
        0.exit;
    };
});
)
