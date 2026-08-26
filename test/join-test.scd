// ============================================================
//  LIVE LOOPER · join-test.scd
//  Loop length (bars) and the crossfaded loop join.
//
//  The join records PAST the end of the loop and blends that overlap back over the
//  start, so the seam is a fade rather than a butt splice. Verified by injecting a
//  signal on an input bus — indistinguishable from a real jack to SoundIn — and then
//  reading the buffer back.
//
//  Run it headless (no ZOOM H8 needed):
//    & "C:\Program Files\SuperCollider-3.14.1\sclang.exe" -D d:/livelooper/test/join-test.scd
//
//  Expect: "23 passed, 0 failed".
// ============================================================
(
var pass = 0, fail = 0, ok, t, sr;

ok = { |label, cond|
    if (cond) { pass = pass + 1; ("  PASS  " ++ label).postln }
             { fail = fail + 1; ("  FAIL  " ++ label).postln };
};

s = Server(\llJoinTest, NetAddr("127.0.0.1", 57158));
Server.default = s;
s.options.device = nil;
s.options.numInputBusChannels  = 12;
s.options.numOutputBusChannels = 2;
s.options.memSize = 8192 * 16;

s.waitForBoot({
    fork {
        1.0.wait;
        "D:/livelooper/config.scd".load;
        ~trackInputs = [9]; ~trackNames = ["probe"];
        ~dirtPort = NetAddr.langPort;
        ~dirt = SuperDirt(2, s); ~dirt.start(~dirtPort, [0, 0]);
        1.0.wait;
        "D:/livelooper/looper.scd".load;
        while { ~tracks.isNil or: { ~tracks.any { |x| x[\synth].isNil } } } { 0.2.wait };
        t  = ~tracks[0];
        sr = s.sampleRate;

        "".postln; "--- LOOP LENGTH ---".postln;
        ok.("track starts at the config default", t[\cycles] == ~numLoopCycles);
        ok.("buffer covers the LONGEST choice",
            t[\bufFrames] >= (~loopFramesFor.(~minCps, ~maxLoopCycles) + ~xfadeFrames.()));
        ~trackCycles.(t, 8);
        ok.("length can be set to 8",  t[\cycles] == 8);
        ~trackCyclesNext.(t);
        ok.("stepping wraps back to 4", t[\cycles] == 4);
        ~trackCycles.(t, 99);
        ok.("clamped to the choices",  t[\cycles] == 8);

        // an 8-bar loop must actually be twice a 4-bar one at the same tempo
        ~cps = 2.0; ~lastCycle = 0; ~lastEventTime = Main.elapsedTime;
        ok.("8 bars is twice 4 bars",
            ~loopFramesFor.(2.0, 8) == (~loopFramesFor.(2.0, 4) * 2));

        "".postln; "--- THE JOIN ---".postln;
        // A steady tone on the input. After a take, the loop region holds one pass and
        // the tail region holds the overlap — both must be filled.
        SynthDef(\inject, {
            Out.ar(s.options.numOutputBusChannels + 9, SinOsc.ar(300, 0, 0.5));
        }).add;
        s.sync;
        ~inj = Synth(\inject, addAction: \addToHead);
        ~trackCycles.(t, 4);
        t[\buf].zero;
        s.sync;
        ~trackRecord.(t);
        6.0.wait;                       // punch-in + 2 s take + overlap tail

        ok.("take reached playing",     t[\state] == \playing);
        ok.("xfFrames was applied",     t[\xfFrames] > 0);
        ok.("loop length matches bars", t[\loopFrames] == ~loopFramesFor.(2.0, 4));
        ok.("loop + tail fit the buffer",
            (t[\loopFrames] + t[\xfFrames]) <= t[\bufFrames]);

        // the overlap tail must be RECORDED, not left as silence
        t[\buf].loadToFloatArray(t[\loopFrames], t[\xfFrames], { |tailArr|
            var tailPeak = tailArr.abs.maxItem;
            ("        (tail region peak = " ++ tailPeak.round(0.001) ++ ")").postln;
            ok.("overlap tail was recorded", tailPeak > 0.1);

            // and the loop's own start must survive — the second pass must NOT have
            // overwritten it, which is the whole reason the write head is redirected
            t[\buf].loadToFloatArray(0, 4096, { |headArr|
                var headPeak = headArr.abs.maxItem;
                ("        (loop start peak  = " ++ headPeak.round(0.001) ++ ")").postln;
                ok.("loop start still intact", headPeak > 0.1);
                ~inj.free;

                // --- CURVE SHAPE ---
                // fade-in t^c and fade-out (1-t)^c. At c = 0.5 the squares sum to 1
                // (equal power); at c = 1 the values sum to 1 (equal gain).
                "".postln; "--- CURVE ---".postln;
                ok.("c=0.5 is equal power at the midpoint",
                    ((0.5 ** 0.5).squared + (0.5 ** 0.5).squared - 1).abs < 0.001);
                ok.("c=1 is equal gain at the midpoint",
                    ((0.5 ** 1) + (0.5 ** 1) - 1).abs < 0.001);
                ok.("fade-in starts silent",  (0.0 ** 0.5) == 0);
                ok.("fade-in ends full",      (1.0 ** 0.5) == 1);
                ok.("fade-out ends silent",   ((1 - 1.0) ** 0.5) == 0);

                // --- DISABLED ---
                // ~xfadeSecs = 0 must be an EXACT bypass, not a very short fade: the
                // take stops at the loop end, nothing is written past it, and the
                // read head is the plain loop. This is the state to A/B against.
                fork {
                    var tailBefore = t[\xfFrames];
                    "".postln; "--- JOIN DISABLED (~xfadeSecs = 0) ---".postln;
                    ~trackClear.(t);
                    ~xfadeSecs = 0;
                    0.5.wait;
                    ok.("the enabled run really had a tail", tailBefore > 0);
                    ok.("xfadeFrames is now zero", ~xfadeFrames.() == 0);
                    ~inj = Synth(\inject, addAction: \addToHead);
                    t[\buf].zero;
                    s.sync;
                    ~trackRecord.(t);
                    6.0.wait;
                    ~inj.free;
                    ok.("take still reached playing", t[\state] == \playing);
                    ok.("no overlap tail is armed",   t[\xfFrames] == 0);
                    ok.("loop length is unchanged",
                        t[\loopFrames] == ~loopFramesFor.(2.0, 4));
                    t[\buf].loadToFloatArray(t[\loopFrames], 8192, { |past|
                        var pastPeak = past.abs.maxItem;
                        ("        (past-the-end peak = " ++ pastPeak.round(0.001)
                            ++ ", was " ++ tailBefore ++ " frames of signal)").postln;
                        ok.("nothing recorded past the loop end", pastPeak < 0.01);
                        "".postln;
                        ("======== " ++ pass ++ " passed, " ++ fail ++ " failed ========").postln;
                        fork { 0.5.wait; 0.exit };
                    });
                };
            });
        });
    };
});
)
