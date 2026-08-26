// ============================================================
//  LIVE LOOPER · tools/latency-measure.scd
//  Measures the audio ROUND TRIP — out of the interface and back in — which is what
//  ~loopOffset exists to compensate.
//
//  WHY THIS AND NOT ~syncWatch
//  ~syncWatch measures where the loop's PHASE sits against Tidal's grid, and that is
//  already locked correctly. What arrives late is the AUDIO inside the loop: you play in
//  time with what you hear, so your playing reaches the converter late by the input
//  latency and comes back late again by the output latency. Only a real out-and-back
//  measurement sees that.
//
//  YOU MUST GIVE IT A PATH BACK IN. Either:
//    A. a cable from the H8's line/headphone out into one of its inputs   (accurate)
//    B. hold the mic against a headphone cup                              (adds a little
//       acoustic delay, ~3 ms per metre — fine if you keep it touching)
//
//  IT MAKES A SHORT LOUD PING. Take your headphones off first.
//
//    "D:/livelooper/tools/latency-measure.scd".load;
//    ~measureLatency.(9);        // the SC input the sound comes back on
// ============================================================

SynthDef(\latPing, { |buf = 0, inChan = 0, out = 0, amp = 0.4|
    // The impulse and the recording start in the SAME block, so the position of the ping
    // inside the buffer IS the round trip — no clock arithmetic needed.
    var trig = Impulse.ar(0);
    var ping = EnvGen.ar(Env.perc(0.0005, 0.015), trig) * SinOsc.ar(2000) * amp;
    RecordBuf.ar(SoundIn.ar(inChan), buf, 0, 1, 0, 1, 0, 1, 2);
    Out.ar(out, ping ! 2);
}).add;

~latResults = ~latResults ? [];

// Onset finder, kept separate so it can be tested without any hardware: the first sample
// clearing a fifth of the peak. The ping is a sharp transient, so this lands within a
// sample or two of the true arrival. Returns nil when nothing came back.
~latOnset = { |arr, floor = 0.02|
    var peak = arr.abs.maxItem;
    var onset = nil;
    if (peak > floor) {
        arr.do { |v, i| if (onset.isNil and: { v.abs > (peak * 0.2) }) { onset = i } };
    };
    [onset, peak];
};

~measureOnce = { |inChan, secs, action|
    var sr  = s.sampleRate ?? { 44100 };
    var buf = Buffer.alloc(s, (sr * secs).round.asInteger, 1);
    s.sync;
    Synth(\latPing, [buf: buf, inChan: inChan]);
    (secs + 0.2).wait;
    buf.loadToFloatArray(0, buf.numFrames, { |a|
        var found = ~latOnset.(a);
        buf.free;
        action.value(found[0] !? { found[0] / sr }, found[1]);
    });
};

~measureLatency = { |inChan = 9, trials = 5, secs = 0.5|
    fork {
        var got = [];
        "".postln;
        "======== ROUND TRIP ========".postln;
        ("listening on SC input " ++ inChan ++ ", " ++ trials ++ " pings.").postln;
        "(loud short ping — headphones off)".postln;
        "".postln;
        trials.do { |k|
            var done = false;
            ~measureOnce.(inChan, secs, { |secsOrNil, peak|
                if (secsOrNil.isNil) {
                    ("  ping " ++ (k + 1) ++ ": nothing came back (peak "
                        ++ peak.round(0.001) ++ ")").postln;
                } {
                    got = got.add(secsOrNil);
                    ("  ping " ++ (k + 1) ++ ": " ++ (secsOrNil * 1000).round(0.1)
                        ++ " ms   (peak " ++ peak.round(0.001) ++ ")").postln;
                };
                done = true;
            });
            while { done.not } { 0.05.wait };
            0.3.wait;
        };
        "".postln;
        if (got.size < 2) {
            "  NO SIGNAL. The ping is not reaching that input.".postln;
            "    - is the cable in the right jack, or the mic against the cup?".postln;
            "    - is that the right SC input? check with tools/input-scan.scd".postln;
            "    - is the H8's input gain up, and the output actually playing?".postln;
        } {
            var sorted = got.sort;
            var med = sorted[sorted.size div: 2];
            var spread = sorted.last - sorted.first;
            ("  median round trip : " ++ (med * 1000).round(0.1) ++ " ms").postln;
            ("  spread            : " ++ (spread * 1000).round(0.1) ++ " ms").postln;
            "".postln;
            ("  current ~loopOffset : " ++ ~loopOffset).postln;
            ("  suggested           : " ++ med.round(0.001)).postln;
            if (spread > 0.005) {
                "  (spread over 5 ms — take the median with a pinch of salt, or re-run)".postln;
            };
            "".postln;
            "  Set it, then CLEAR and RE-RECORD — ~loopOffset is read when you hit".postln;
            "  record, so loops already cut keep the old value.".postln;
            ("      ~loopOffset = " ++ med.round(0.001) ++ ";").postln;
            "  Then trim by ear: still late -> up, now early -> down.".postln;
        };
        "============================".postln;
        "".postln;
    };
};

"tools/latency-measure.scd loaded — run:  ~measureLatency.(9);   (see the header first)".postln;
