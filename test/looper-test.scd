// ============================================================
//  LIVE LOOPER · looper-test.scd
//  Covers the record path: state machine, loop length, and the guarantee that hitting
//  record never allocates (the buffer is pre-allocated at the ~minCps worst case and
//  only \loopFrames moves). Ends by metering the real output bus, so the mono-buffer
//  to stereo-out path is verified as audio rather than assumed.
//
//  Run it headless (does NOT need the ZOOM H8 — boots the system default device):
//    & "C:\Program Files\SuperCollider-3.14.1\sclang.exe" -D d:/livelooper/test/looper-test.scd
//
//  Expect: "33 passed, 0 failed".
// ============================================================
(
var pass = 0, fail = 0, ok, t, bufBefore, framesAt2, gotFrames;

ok = { |label, cond|
    if (cond) { pass = pass + 1; ("  PASS  " ++ label).postln }
             { fail = fail + 1; ("  FAIL  " ++ label).postln };
};

// Dedicated server + port, so this is safe to run even while your rig is booted on the
// default 57110 — and so suites run back-to-back can't collide on a lingering scsynth.
s = Server(\llLooperTest, NetAddr("127.0.0.1", 57114));
Server.default = s;
s.options.device = nil;                 // system default — no ZOOM H8 needed
s.options.numInputBusChannels  = 12;
s.options.numOutputBusChannels = 2;
s.options.memSize = 8192 * 16;

s.waitForBoot({
    fork {
        1.0.wait;
        "D:/livelooper/config.scd".load;
        // Pin a known all-mono layout. This suite tests the mono record path and fills
        // buffers assuming mono framing, so it must not depend on the rig's real input
        // map — which now leads with a STEREO mic. Stereo has its own suite.
        ~trackInputs = [9, 8, 5];
        ~trackNames  = ["a", "b", "c"];
        // SuperDirt without its sample library — none of it matters here.
        ~dirtPort = NetAddr.langPort;
        ~dirt = SuperDirt(2, s);
        ~dirt.start(~dirtPort, [0, 0]);
        1.0.wait;
        "D:/livelooper/looper.scd".load;
        // Wait for the build fork to finish rather than guessing: allocating the
        // pre-sized buffers takes as long as it takes.
        while { ~tracks.isNil or: { ~tracks.any { |x| x[\synth].isNil } } } { 0.2.wait };

        t = ~tracks[0];

        "".postln; "--- PRE-ALLOCATION ---".postln;
        ok.("buffer exists",             t[\buf].notNil);
        ok.("buffer is mono",            t[\buf].numChannels == 1);
        // sized for the LONGEST selectable loop at the slowest tempo, plus the join tail
        ok.("sized for the longest loop", t[\bufFrames]
            == (~loopFramesFor.(~minCps, ~maxLoopCycles) + ~tailFrames.()));
        ok.("track starts idle",         t[\state] == \idle);

        // Deterministic clock: set the tempo directly rather than racing OSC.
        ~cps = 2.0;                      // 4 cycles = 2 s
        ~lastCycle = 0; ~lastEventTime = Main.elapsedTime;
        framesAt2 = ~loopFramesFor.(2.0);
        bufBefore = t[\buf].bufnum;

        "".postln; "--- RECORD ---".postln;
        ~trackRecord.(t);                  // idle -> recording
        ok.("state -> recording",        t[\state] == \recording);
        ok.("loop length matches tempo", t[\loopFrames] == framesAt2);
        ok.("NO reallocation on record", t[\buf].bufnum == bufBefore);
        ok.("loop shorter than buffer",  t[\loopFrames] < t[\bufFrames]);

        4.0.wait;                        // downbeat wait + 2 s of recording
        ok.("state -> playing",          t[\state] == \playing);
        ok.("buffer still the same one", t[\buf].bufnum == bufBefore);

        // prove the control actually reached the server, not just the language
        gotFrames = nil;
        t[\synth].get(\loopFrames, { |v| gotFrames = v });
        0.5.wait;
        ok.("server has the loop length", gotFrames == framesAt2);

        "".postln; "--- OVERDUB / CLEAR ---".postln;
        ~trackOverdub.(t);               // playing -> overdub
        ok.("state -> overdub",          t[\state] == \overdub);
        ~trackOverdub.(t);               // overdub -> playing
        ok.("state -> playing again",    t[\state] == \playing);
        ~trackClear.(t);
        ok.("state -> idle after clear", t[\state] == \idle);
        ok.("clear keeps the buffer",    t[\buf].notNil and: { t[\buf].bufnum == bufBefore });

        // --- RECORD OVER A PLAYING LOOP ---
        // The point of splitting record from overdub: punching in over a playing loop
        // must NOT require clearing first, and must not be mistaken for an overdub.
        "".postln; "--- RECORD OVER A PLAYING LOOP ---".postln;
        ~cps = 2.0; ~lastCycle = 0; ~lastEventTime = Main.elapsedTime;
        ~trackRecord.(t);
        4.0.wait;
        ok.("track is playing",           t[\state] == \playing);
        ~trackRecord.(t);                 // punch in again, no clear
        ok.("record over playing re-arms", t[\state] == \recording);
        4.0.wait;
        ok.("and returns to playing",     t[\state] == \playing);
        // overdub on an EMPTY track must be a no-op, not a surprise recording
        ~trackClear.(t);
        0.2.wait;
        ~trackOverdub.(t);
        ok.("overdub on empty is ignored", t[\state] == \idle);

        "".postln; "--- TEMPO BELOW ~minCps ---".postln;
        // Slower than the buffer was sized for: the loop must clamp to the buffer rather
        // than run off the end, and say so. (A warning is expected here.)
        ~cps = ~minCps / 2;
        ~lastCycle = 0; ~lastEventTime = Main.elapsedTime;
        ~trackRecord.(t);
        // clamps to what is left after reserving the join tail
        ok.("clamped to buffer length",  t[\loopFrames] == (t[\bufFrames] - t[\tailFrames]));
        ok.("did not exceed the buffer", t[\loopFrames] <= t[\bufFrames]);
        ~trackClear.(t);                 // cancel the pending take
        0.5.wait;
        ok.("clear cancels the take",    t[\state] == \idle);

        // untouched neighbours
        ok.("other tracks still idle",   ~tracks[1..].every { |x| x[\state] == \idle });

        // --- PHRASE ALIGNMENT ---
        // Two loops punched in at different moments must land on the SAME grid. With
        // quantize = 1 they can end up half a phrase apart: each on the beat, but not
        // stacking. That is what put t2 two cycles out from t0/t1 on the real rig.
        "".postln; "--- PHRASE ALIGNMENT ---".postln;
        ~cps = 2.0; ~lastCycle = 0; ~lastEventTime = Main.elapsedTime;
        ~trackClear.(~tracks[0]);
        ~trackRecord.(~tracks[0]);
        0.9.wait;                        // punch the second one in mid-phrase
        ~trackRecord.(~tracks[1]);
        0.2.wait;
        // The loops are punched in on DIFFERENT measures on purpose. They must still
        // stack, because the buffer is locked to the phrase grid: each one's start
        // phase has to equal its start cycle's position within the phrase.
        ("        (startCycles: " ++ ~tracks[0][\startCycle] ++ ", " ++ ~tracks[1][\startCycle]
            ++ "  startPhases: " ++ ~tracks[0][\startPhase].round(0.001) ++ ", "
            ++ ~tracks[1][\startPhase].round(0.001)
            ++ "  quantize=" ++ ~recordQuantize ++ ")").postln;
        ok.("punch-in was NOT forced to a phrase boundary",
            (~tracks[0][\startCycle] % ~numLoopCycles) != (~tracks[1][\startCycle] % ~numLoopCycles));
        ok.("t0 phase matches its start cycle",
            (~tracks[0][\startPhase]
                - ((~tracks[0][\startCycle] % ~numLoopCycles) / ~numLoopCycles)).abs < 0.01);
        ok.("t1 phase matches its start cycle",
            (~tracks[1][\startPhase]
                - ((~tracks[1][\startCycle] % ~numLoopCycles) / ~numLoopCycles)).abs < 0.01);
        // grid position = start cycle offset minus start phase; equal for aligned loops
        ok.("both loops share one grid",
            ((~tracks[0][\startCycle] - (~tracks[0][\startPhase] * ~numLoopCycles))
                % ~numLoopCycles
             - ((~tracks[1][\startCycle] - (~tracks[1][\startPhase] * ~numLoopCycles))
                % ~numLoopCycles)).abs < 0.01);

        // --- \reset MUST NOT STICK ---
        // Phasor only resets on a RISING edge. If the clear lands before the set, reset
        // stays at 1 and every later record silently fails to reset the phase — which
        // reads as a sudden, permanent desync.
        "".postln; "--- RESET EDGE ---".postln;
        6.0.wait;                        // let both takes finish
        gotFrames = nil;
        ~tracks[0][\synth].get(\reset, { |v| gotFrames = v });
        0.5.wait;
        ok.("reset returned to 0 after record", gotFrames == 0);
        ~trackClear.(~tracks[1]);
        ~trackRecord.(~tracks[1]);         // a SECOND record must still get a rising edge
        6.0.wait;
        gotFrames = nil;
        ~tracks[1][\synth].get(\reset, { |v| gotFrames = v });
        0.5.wait;
        ok.("reset returned to 0 after re-record", gotFrames == 0);
        ok.("re-record still reached playing", ~tracks[1][\state] == \playing);

        // --- SIGNAL PATH ---
        // The loop is stored mono and widened with `! 2` at the output. Assert that as
        // audio rather than trusting it: write a known DC level into the buffer, then
        // meter the actual output bus.
        "".postln; "--- SIGNAL PATH (mono buffer -> stereo out) ---".postln;
        SynthDef(\ltMeter, {
            SendReply.kr(Impulse.kr(10), '/ltMeter', Amplitude.kr(In.ar(0, 2), 0.01, 0.05));
        }).add;
        s.sync;
        OSCFunc({ |msg| ~mL = msg[3]; ~mR = msg[4] }, '/ltMeter');
        t[\buf].fill(0, t[\bufFrames], 0.5);
        t[\synth].set(\recRun, 0, \recLevel, 0, \preLevel, 1,
            \playing, 1, \monLevel, 0, \level, 1.0);
        ~meter = Synth(\ltMeter, addAction: \addToTail);
        1.5.wait;
        ("        (L = " ++ ~mL.round(0.001) ++ ", R = " ++ ~mR.round(0.001) ++ ")").postln;
        ok.("loop audible on LEFT",      (~mL - 0.5).abs < 0.05);
        ok.("loop audible on RIGHT",     (~mR - 0.5).abs < 0.05);
        t[\synth].set(\playing, 0);
        1.0.wait;
        ok.("playing=0 silences it",     ~mL < 0.02);
        ~meter.free;

        "".postln;
        ("======== " ++ pass ++ " passed, " ++ fail ++ " failed ========").postln;
        0.5.wait;
        0.exit;
    };
});
)

