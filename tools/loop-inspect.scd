// ============================================================
//  LIVE LOOPER · tools/loop-inspect.scd
//  Reads a recorded loop back off the server and looks for holes in it.
//
//    "D:/livelooper/tools/loop-inspect.scd".load;
//    ~loopInspect.(0);          // inspect track 0 (works while it's playing)
//
//  Silence at the loop point usually means the recording WINDOW was offset from the
//  music: the grid is anchored to when Tidal's message ARRIVED rather than when it
//  SOUNDS, so recording can begin early, catching silence at the head and clipping the
//  tail. The report compares any gap it finds against exactly that prediction.
// ============================================================

~loopInspect = { |trackIdx = 0, winMs = 5, threshDb = -45|
    var t = ~tracks[trackIdx];
    if (t.isNil or: { t[\buf].isNil or: { t[\loopFrames].isNil } }) {
        "loop-inspect: nothing recorded on that track.".postln;
    } {
        t[\buf].loadToFloatArray(0, t[\loopFrames], { |arr|
            var sr, win, nWin, rms, peak, thresh, runs, cur, loopSecs, predicted;
            sr       = s.sampleRate ? 44100;
            loopSecs = t[\loopFrames] / sr;
            win      = (winMs / 1000 * sr).round.asInteger.max(1);
            nWin     = (arr.size / win).floor.asInteger;

            // RMS per window
            rms = Array.fill(nWin, { |i|
                var sum = 0;
                win.do { |j| var v = arr[(i * win) + j]; sum = sum + (v * v) };
                (sum / win).sqrt;
            });
            peak   = rms.maxItem;
            thresh = peak * threshDb.dbamp;

            // contiguous runs below threshold
            runs = List.new; cur = nil;
            rms.do { |v, i|
                if (v < thresh) {
                    cur ?? { cur = (start: i, len: 0) };
                    cur[\len] = cur[\len] + 1;
                } {
                    cur !? { runs.add(cur); cur = nil };
                };
            };
            cur !? { runs.add(cur) };

            "".postln;
            "======== LOOP INSPECT ========".postln;
            ("track            : " ++ trackIdx ++ "  (" ++ t[\state] ++ ")").postln;
            ("loop length      : " ++ t[\loopFrames] ++ " frames = "
                ++ loopSecs.round(0.001) ++ " s").postln;
            ("expected at cps  : " ++ (~numLoopCycles / ~cps).round(0.001) ++ " s"
                ++ "   -> " ++ if (((t[\loopFrames] / sr) - (~numLoopCycles / ~cps)).abs < 0.01)
                    { "buffer length is correct" } { "*** BUFFER LENGTH IS WRONG ***" }).postln;
            ("peak window rms  : " ++ peak.round(0.0001)
                ++ "   silence threshold " ++ threshDb ++ " dB").postln;
            ("start phase      : " ++ ((t[\startPhase] ? 0) * 100).round(0.1)
                ++ "% into the loop  (where recording began)").postln;
            "".postln;

            if (runs.isEmpty) {
                "  no silent regions — the loop is full.".postln;
            } {
                // report the biggest holes first
                runs = runs.asArray.sort { |a, b| a[\len] > b[\len] };
                "  silent regions (longest first):".postln;
                runs.keep(5).do { |r|
                    var atMs  = r[\start] * win / sr * 1000;
                    var lenMs = r[\len] * win / sr * 1000;
                    ("    " ++ lenMs.round(0.1).asString.padLeft(8) ++ " ms  at "
                        ++ atMs.round(0.1).asString.padLeft(8) ++ " ms  ("
                        ++ (atMs / 1000 / loopSecs * 100).round(0.1) ++ "% into the loop)"
                    ).postln;
                };
                "".postln;
                // The predicted hole: recording starts early by the lookahead, which the
                // click calibration already measured as ~clickOffset + s.latency.
                predicted = ((~clickOffset ? 0) + s.latency) * 1000;
                ("  predicted hole if the grid anchor is early: "
                    ++ predicted.round(0.1) ++ " ms").postln;
                ("  longest hole found: " ++ (runs[0][\len] * win / sr * 1000).round(0.1)
                    ++ " ms").postln;
                if (((runs[0][\len] * win / sr * 1000) - predicted).abs < (predicted * 0.4)) {
                    "  *** MATCHES — the recording window is offset from the music. ***".postln;
                } {
                    "  (does not match that prediction — something else)".postln;
                };
            };
            "==============================".postln;
            "".postln;
        });
    };
};

"tools/loop-inspect.scd loaded — run:  ~loopInspect.(0);".postln;
