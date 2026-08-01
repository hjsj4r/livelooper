// ============================================================
//  LIVE LOOPER · tools/sync-check.scd
//  Prints everything that determines whether loops line up with the patterns.
//  Run it WHILE the problem is happening — ideally with Tidal playing and at least
//  one loop recorded.
//
//    "D:/livelooper/tools/sync-check.scd".load;     // snapshot
//    ~syncCheck.();                                 // again, any time
//    ~syncWatch.();                                 // live drift monitor (~syncWatchStop.())
// ============================================================

~syncCheck = {
    var sr, cfgSr, since, expSecs, expFrames;
    sr    = s.sampleRate;
    cfgSr = ~sampleRate;
    since = ~lastEventTime !? { Main.elapsedTime - ~lastEventTime };

    "".postln;
    "======== SYNC CHECK ========".postln;

    // 1. Sample rate. Loop length is computed in FRAMES, so if the server is not running
    //    at the rate we think, every loop is the wrong duration by exactly that ratio.
    ("server sampleRate : " ++ sr).postln;
    ("config ~sampleRate: " ++ cfgSr).postln;
    if (sr.notNil and: { sr != cfgSr }) {
        ("  *** MISMATCH — loops will be off by " ++ ((sr / cfgSr - 1) * 100).round(0.01)
            ++ "%. Fix the H8's rate or ~sampleRate in config.scd. ***").postln;
    } { "  ok — rates agree".postln };

    // 2. Is tempo tracking alive? Everything downstream depends on ~cps being current.
    "".postln;
    ("~cps              : " ++ ~cps).postln;
    ("~lastCycle        : " ++ ~lastCycle).postln;
    if (since.isNil) {
        "  *** NO PATTERN EVENT EVER SEEN — ~dirt.receiveAction is not firing.".postln;
        "      ~cps is stuck at its default, so loop lengths are wrong. ***".postln;
    } {
        ("last event        : " ++ since.round(0.01) ++ " s ago").postln;
        if (since > 5) {
            "  (nothing recently — is Tidal actually playing? the clock free-runs)".postln;
        } { "  ok — receiveAction is firing".postln };
    };
    ("receiveAction set : " ++ (~dirt !? { ~dirt.receiveAction.notNil })).postln;

    // 3. Loop geometry.
    "".postln;
    expSecs   = ~numLoopCycles / (~cps ? 0.5);
    expFrames = ~loopFramesFor.(~cps ? 0.5);
    ("~numLoopCycles    : " ++ ~numLoopCycles).postln;
    ("~loopOffset       : " ++ ~loopOffset).postln;
    ("s.latency         : " ++ s.latency).postln;
    ("a loop at this cps: " ++ expSecs.round(0.001) ++ " s  = " ++ expFrames ++ " frames").postln;

    "".postln;
    ~tracks.do { |t|
        var f    = t[\loopFrames];
        var secs = (f.notNil and: { sr.notNil }).if({ f / sr }, { nil });
        var musicalCps = (secs.notNil and: { secs > 0 }).if({ ~numLoopCycles / secs }, { nil });
        ("t" ++ t[\idx] ++ " in" ++ t[\input]
            ++ "  state=" ++ t[\state]
            ++ "  frames=" ++ f
            ++ "  = " ++ (secs !? { secs.round(0.001) }) ++ " s"
            ++ "  -> implies cps " ++ (musicalCps !? { musicalCps.round(0.0001) })
            ++ "  startCycle=" ++ t[\startCycle]).postln;
    };
    "  (a loop's implied cps should match ~cps at the time it was recorded)".postln;
    "============================".postln;
    "".postln;
};

// Live alignment. Two separate numbers, because they mean different things:
//
//   OFFSET — where the loop sits against the patterns right now. Anchored to when the
//            loop's phase actually restarted (t[\loopStartTime]), so a big constant
//            value means the loop STARTED in the wrong place.
//   CREEP  — how much that offset has moved since watching began. The audio clock and
//            Tidal's clock are different clocks, so a slow creep is normal; a fast one
//            means the loop LENGTH is wrong.
~syncWatchStop = {
    ~syncWatchTask !? { ~syncWatchTask.stop; ~syncWatchTask = nil };
    "sync watch stopped.".postln;
};

// A loop is a fixed number of SAMPLES. Tidal's cycle is a duration that changes with
// cps. If those disagree the loop slips by the difference on every single repeat — which
// is heard as a sudden, permanent desync rather than a gradual drift.
~syncTempoReport = { |loopCps, loopSecs|
    var wantSecs = ~numLoopCycles / ~cps;
    var slipMs   = (loopSecs - wantSecs) * 1000;
    ("    loop cut at cps " ++ loopCps.round(0.0001)
        ++ "  |  Tidal now at cps " ++ (~cps).round(0.0001)).postln;
    if (slipMs.abs < 5) {
        ("    tempos agree — slip " ++ slipMs.round(0.1) ++ " ms per repeat").postln;
    } {
        ("    *** MISMATCH: this loop slips " ++ slipMs.round(0.1)
            ++ " ms EVERY repeat (" ++ (slipMs / loopSecs / 10).round(0.01) ++ "% off) ***").postln;
        ("    *** A full beat out after ~"
            ++ ((1000 / (~cps * ~clickDiv) / slipMs.abs) * loopSecs).round(0.1)
            ++ " s. Re-record the loop at the current tempo. ***").postln;
    };
};

~syncWatch = { |trackIdx = 0, everySecs = 2|
    var t = ~tracks[trackIdx];
    ~syncWatchStop.();
    case
    { t[\loopFrames].isNil or: { t[\startCycle].isNil } } {
        "sync watch: record a loop on that track first.".postln;
    }
    { t[\loopStartTime].isNil or: { t[\startPhase].isNil } } {
        "sync watch: no loop start recorded — re-record the loop, then watch again.".postln;
    }
    {
        ~syncWatchTask = Task({
            var sr = s.sampleRate;
            var loopSecs = t[\loopFrames] / sr;
            var loopCps  = ~numLoopCycles / loopSecs;     // the tempo this loop was cut at
            var t0 = Main.elapsedTime, first = nil, prevOffset = nil, prevCps = ~cps;
            var slip;

            ("watching t" ++ trackIdx ++ " — loop is " ++ loopSecs.round(0.001) ++ " s"
                ++ ", recorded at cps " ++ loopCps.round(0.0001)).postln;
            "  offset should sit near 0; creep should stay near 0.".postln;
            ~syncTempoReport.(loopCps, loopSecs);

            loop {
                var nowCps = ~cps;
                var tidalPos, audioPos, offset, jump;

                // A tempo change is INSTANT desync: the loop's length is frozen in
                // samples, so it can no longer match a cycle of a different duration.
                if ((nowCps - prevCps).abs > 1e-9) {
                    "".postln;
                    ("  *** TEMPO CHANGED: cps " ++ prevCps ++ " -> " ++ nowCps ++ " ***").postln;
                    ~syncTempoReport.(loopCps, loopSecs);
                    "".postln;
                    prevCps = nowCps;
                };

                // Both positions are measured against the ABSOLUTE phrase grid, not
                // against when this loop happened to be armed — that is the whole point
                // of locking the buffer to the grid, and it means this also catches two
                // loops sitting on different grids.
                tidalPos = (~nowCycle.() / ~numLoopCycles) % 1;
                audioPos = ((t[\startPhase] ? 0)
                    + ((Main.elapsedTime - t[\loopStartTime]) / loopSecs)) % 1;
                offset   = (tidalPos - audioPos + 0.5) % 1 - 0.5;    // wrap to [-0.5, 0.5)
                first ?? { first = offset };
                jump = prevOffset !? { (offset - prevOffset) * loopSecs * 1000 };
                prevOffset = offset;

                ("  t+" ++ (Main.elapsedTime - t0).round(1).asInteger ++ "s"
                    ++ "   offset " ++ (offset * loopSecs * 1000).round(1) ++ " ms"
                    ++ "   creep " ++ ((offset - first) * loopSecs * 1000).round(1) ++ " ms"
                    ++ (jump.notNil and: { jump.abs > 50 }).if(
                        { "   <<< JUMPED " ++ jump.round(1) ++ " ms" }, { "" })
                ).postln;
                everySecs.wait;
            };
        }).play(SystemClock);
    };
};

~syncCheck.();
"tools/sync-check.scd loaded — ~syncCheck.() / ~syncWatch.(0) / ~syncWatchStop.()".postln;
