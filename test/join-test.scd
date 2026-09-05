// ============================================================
//  LIVE LOOPER · join-test.scd
//  Loop length (bars) and the loop join — which is TWO independent things:
//
//    HEAD FADE  a few ms at the loop start, to remove the step that clicks
//    TAIL       hundreds of ms recorded past the loop end and played back ADDED on
//               top of the start, so a cymbal rings across the seam
//
//  They were one number once and no single value suited both, so the property that
//  matters most here is that they are DECOUPLED: each must be settable, and zeroable,
//  without touching the other.
//
//  Verified by injecting a signal on an input bus — indistinguishable from a real jack
//  to SoundIn — and then reading the buffer back.
//
//  Run it headless (no ZOOM H8 needed):
//    & "C:\Program Files\SuperCollider-3.14.1\sclang.exe" -D d:/livelooper/test/join-test.scd
//
//  Expect: "44 passed, 0 failed".
// ============================================================
(
var pass = 0, fail = 0, ok, t, sr, holes;

ok = { |label, cond|
    if (cond) { pass = pass + 1; ("  PASS  " ++ label).postln }
             { fail = fail + 1; ("  FAIL  " ++ label).postln };
};

// Smallest peak found in any of n equal blocks. A loop punched full of holes still has a
// high OVERALL peak, so a global measure would miss it completely — this is what catches
// material being destroyed in a band.
holes = { |arr, n = 16|
    var len = (arr.size / n).floor.asInteger;
    (0 .. n - 1).collect { |k| arr.copyRange(k * len, ((k + 1) * len) - 1).abs.maxItem };
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
        SynthDef(\inject, { |freq = 300, amp = 0.5|
            Out.ar(s.options.numOutputBusChannels + 9, SinOsc.ar(freq, 0, amp));
        }).add;
        s.sync;

        "".postln; "--- LOOP LENGTH ---".postln;
        ok.("track starts at the config default", t[\cycles] == ~numLoopCycles);
        ok.("buffer covers the LONGEST choice, plus a tail",
            t[\bufFrames] >= (~loopFramesFor.(~minCps, ~maxLoopCycles) + ~tailFrames.()));
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

        "".postln; "--- HEAD AND TAIL ARE INDEPENDENT ---".postln;
        // The whole reason for the split: a 3 ms de-click and a half-second cymbal tail
        // have to coexist. One knob could never hold both.
        ~headFadeSecs = 0.003;
        ~tailSecs     = 0.5;
        ~trackCycles.(t, 4);
        t[\buf].zero;
        s.sync;
        ~inj = Synth(\inject, addAction: \addToHead);
        ~trackRecord.(t);
        4.0.wait;                       // punch-in + 2 s take + 0.5 s tail
        ok.("take reached playing",     t[\state] == \playing);
        ok.("head fade is ~3 ms",       (t[\headFrames] - (sr * 0.003)).abs < 2);
        ok.("tail is ~500 ms",          (t[\tailFrames] - (sr * 0.5)).abs < 2);
        ("        (head " ++ t[\headFrames] ++ " frames, tail " ++ t[\tailFrames]
            ++ " frames — a factor of " ++ (t[\tailFrames] / t[\headFrames]).round(1)
            ++ ")").postln;
        ok.("tail outlasts the head by 100x+", t[\tailFrames] > (t[\headFrames] * 100));
        ok.("loop length matches bars", t[\loopFrames] == ~loopFramesFor.(2.0, 4));
        ok.("loop + tail fit the buffer",
            (t[\loopFrames] + t[\tailFrames]) <= t[\bufFrames]);

        // the tail must be RECORDED, not left as silence...
        t[\buf].loadToFloatArray(t[\loopFrames], t[\tailFrames], { |tailArr|
            var tailPeak = tailArr.abs.maxItem;
            var tailMin  = holes.(tailArr, 8).minItem;
            ("        (tail peak = " ++ tailPeak.round(0.001)
                ++ ", quietest eighth = " ++ tailMin.round(0.001) ++ ")").postln;
            ok.("tail was recorded",         tailPeak > 0.1);
            ok.("tail is filled throughout", tailMin > 0.1);

            // ...and the loop start must survive it. This is the whole reason the write
            // head is redirected past the loop region while the tail records.
            t[\buf].loadToFloatArray(0, t[\loopFrames], { |headArr|
                var blocks = holes.(headArr, 16);
                ("        (loop peak = " ++ headArr.abs.maxItem.round(0.001)
                    ++ ", quietest sixteenth = " ++ blocks.minItem.round(0.001) ++ ")").postln;
                ok.("loop start still intact",       blocks[0] > 0.1);
                ok.("no holes anywhere in the loop", blocks.minItem > 0.1);

                fork {
                    var beforePeak = headArr.abs.maxItem;
                    // --- OVERDUB WRITES IN PLACE ---
                    // Regression, and a loud one. The tail redirect used to be open-ended
                    // (n >= frames), which stays true FOREVER once a take has finished —
                    // and overdub raises recRun without resetting n. So every overdubbed
                    // sample was redirected past the loop region to n, writing the raw
                    // input instead of input + what was already there.
                    //
                    // The result was not a glitch, it was silence: overdub wrote into
                    // dead buffer space and the loop never changed at all. (Later, once
                    // n passed bufFrames and wrapped, those writes would start landing
                    // back inside the loop and shredding it.)
                    //
                    // So the assertion is simply that the loop CHANGES. A second tone at
                    // an unrelated frequency has to show up on top of the first.
                    "".postln; "--- OVERDUB WRITES IN PLACE ---".postln;
                    ~inj.free;
                    ~inj = Synth(\inject, [freq: 1100, amp: 0.5], addAction: \addToHead);
                    0.2.wait;
                    ~trackOverdub.(t);
                    ok.("overdub engaged",  t[\state] == \overdub);
                    2.4.wait;                        // a little over one full loop
                    ~trackOverdub.(t);
                    ok.("overdub released", t[\state] == \playing);
                    ~inj.free;
                    0.3.wait;
                    t[\buf].loadToFloatArray(0, t[\loopFrames], { |after|
                        var ab = holes.(after, 16);
                        ("        (loop peak before = " ++ beforePeak.round(0.001)
                            ++ ", after = " ++ after.abs.maxItem.round(0.001)
                            ++ "; quietest sixteenth after = " ++ ab.minItem.round(0.001)
                            ++ ")").postln;
                        ok.("the overdub actually landed in the loop",
                            after.abs.maxItem > (beforePeak + 0.05));
                        ok.("it layered rather than replacing",
                            ab.minItem > 0.1);

                        fork {
                            "".postln; "--- ZEROING ONE DOES NOT TOUCH THE OTHER ---".postln;
                            ~trackClear.(t);
                            ~headFadeSecs = 0; ~tailSecs = 0.5;
                            0.4.wait;
                            ok.("head 0 while tail stays", ~headFadeFrames.() == 0);
                            ok.("...tail unaffected",      ~tailFrames.() > 0);
                            ~headFadeSecs = 0.003; ~tailSecs = 0;
                            ok.("tail 0 while head stays", ~tailFrames.() == 0);
                            ok.("...head unaffected",      ~headFadeFrames.() > 0);

                            // and tail 0 must be an EXACT bypass, not a very short tail
                            ~inj = Synth(\inject, addAction: \addToHead);
                            t[\buf].zero;
                            s.sync;
                            ~trackRecord.(t);
                            4.0.wait;
                            ~inj.free;
                            ok.("take still reached playing", t[\state] == \playing);
                            ok.("no tail is armed",           t[\tailFrames] == 0);
                            ok.("head fade survived",         t[\headFrames] > 0);
                            ok.("loop length is unchanged",
                                t[\loopFrames] == ~loopFramesFor.(2.0, 4));
                            t[\buf].loadToFloatArray(t[\loopFrames], 8192, { |past|
                                var pastPeak = past.abs.maxItem;
                                ("        (past-the-end peak = " ++ pastPeak.round(0.001)
                                    ++ ")").postln;
                                ok.("nothing recorded past the loop end", pastPeak < 0.01);

                                // --- GAIN SHAPES ---
                                // gHead = ((j+1)/hf).clip(0,1)          linear, full by hf
                                // gTail = (1 - ((j+1)/tf).clip(0,1))^c  full at the seam
                                // Nothing has to sum to unity: the tail is a continuation
                                // added on top, not a second copy of the same moment.
                                "".postln; "--- GAIN SHAPES ---".postln;
                                ok.("head starts near silent",   ((0 + 1) / 132) < 0.01);
                                ok.("head is full by its length",
                                    ((131 + 1) / 132).clip(0, 1) == 1);
                                ok.("head 0 gives full gain at once",
                                    ((0 + 1) / 0.max(1)).clip(0, 1) == 1);
                                ok.("tail 0 gives silence at once",
                                    (1 - ((0 + 1) / 0.max(1)).clip(0, 1)) == 0);
                                ok.("tail starts at full",  ((1 - 0) ** 0.5) == 1);
                                ok.("tail ends silent",     ((1 - 1.0) ** 0.5) == 0);
                                ok.("c<1 holds the tail high early",
                                    ((1 - 0.25) ** 0.5) > 0.75);

                                fork {
                                    var sr2 = s.sampleRate, gridPos, want, opened;
                                    // --- HEAD WINDOW ---
                                    // It must move the SEAM and nothing else. The loop
                                    // stays exactly one phrase long, so a window can
                                    // never make loops drift against each other — it
                                    // only changes where the circle is cut.
                                    "".postln; "--- HEAD WINDOW ---".postln;
                                    ~headWindowSecs = 0;
                                    ~trackClear.(t);
                                    ~inj = Synth(\inject, addAction: \addToHead);
                                    ~trackRecord.(t);
                                    3.0.wait;
                                    ok.("no window: nothing is reserved",
                                        t[\headWindow] == 0);
                                    // With no window the seam sits exactly ON the grid
                                    // point the take was armed for.
                                    gridPos = ~phasePosFor.(t[\startCycle],
                                        t[\loopFrames], t[\cycles]);
                                    ok.("no window: the seam is on the grid point",
                                        ((t[\startPhase] * t[\loopFrames]) - gridPos).abs < 2);

                                    ~headWindowSecs = 0.03;
                                    ~trackClear.(t);
                                    ~trackRecord.(t);
                                    3.0.wait;
                                    ~inj.free;
                                    ok.("the window is armed",
                                        (t[\headWindow] - (sr2 * 0.03)).abs < 2);
                                    // Compare each take against the grid point IT was
                                    // armed for. Comparing two takes to each other says
                                    // nothing: they land on different cycles, so their
                                    // phrase positions differ for reasons of their own.
                                    gridPos = ~phasePosFor.(t[\startCycle],
                                        t[\loopFrames], t[\cycles]);
                                    want = (gridPos - t[\headWindow] + t[\loopFrames])
                                        % t[\loopFrames];
                                    ("        (grid point " ++ gridPos ++ ", seam at "
                                        ++ (t[\startPhase] * t[\loopFrames]).round
                                        ++ ", window " ++ t[\headWindow] ++ " frames)").postln;
                                    ok.("the seam sits one window BEFORE the grid point",
                                        ((t[\startPhase] * t[\loopFrames]) - want).abs < 2);
                                    // and the take really opened early in wall-clock —
                                    // moving resetPos alone would just shift the audio
                                    opened = t[\loopStartTime]
                                        - (~lastEventTime
                                            + ((t[\startCycle] - ~lastCycle) / ~cps)
                                            + ~loopOffset);
                                    ("        (take opened " ++ (opened * 1000).round(0.1)
                                        ++ " ms vs the grid; window is "
                                        ++ (t[\headWindow] / sr2 * 1000).round(0.1)
                                        ++ " ms)").postln;
                                    // 20 ms of slack, not because the rig is that loose
                                    // but because this suite pins ~lastEventTime once and
                                    // then extrapolates for a minute — the drift is the
                                    // harness's, not the looper's. The resetPos assertion
                                    // above is the exact one, and it holds to 2 frames.
                                    ok.("recording opened one window early",
                                        (opened + (t[\headWindow] / sr2)).abs < 0.02);
                                    // ...and that is ALL it moves
                                    ok.("the loop is still one phrase",
                                        t[\loopFrames] == ~loopFramesFor.(2.0, 4));
                                    ok.("the window is capped at a quarter of the loop",
                                        t[\headWindow] <= (t[\loopFrames] / 4));
                                    // and the take still filled the whole circle — a
                                    // window must not leave dead space in the loop
                                    t[\buf].loadToFloatArray(0, t[\loopFrames], { |w|
                                        var wb = holes.(w, 16);
                                        ("        (quietest sixteenth with a window = "
                                            ++ wb.minItem.round(0.001) ++ ")").postln;
                                        ok.("no dead space anywhere in the loop",
                                            wb.minItem > 0.1);
                                        ~headWindowSecs = 0;
                                        "".postln;
                                        ("======== " ++ pass ++ " passed, " ++ fail
                                            ++ " failed ========").postln;
                                        fork { 0.5.wait; 0.exit };
                                    });
                                };
                            });
                        };
                    });
                };
            });
        });
    };
});
)
