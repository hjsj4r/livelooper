// ============================================================
//  LIVE LOOPER · tools/click-calibrate.scd
//  Works out ~clickOffset from measurement instead of by ear.
//
//  WHAT THIS CHECKS NOW
//  Tidal sends each event AHEAD of when it should sound, timestamped with its intended
//  sounding time, and sclang hands the message over immediately (verified: a bundle sent
//  0.3 s ahead arrives now, with time = now + 0.3).
//
//  looper.scd anchors the beat grid to ev[\timeStamp], so that lookahead is already
//  accounted for and the ideal ~clickOffset is 0. This tool now measures the lookahead
//  (informational) and CONFIRMS the anchor is correct — if the anchor ever regressed to
//  Main.elapsedTime, recordings would start early again and leave a hole at the punch-in
//  point (tools/loop-inspect.scd finds those).
//
//  USAGE — with Tidal actually playing a pattern:
//      "D:/livelooper/tools/click-calibrate.scd".load;
//      ~clickCalibrate.();        // listens to ~64 events, then prints the answer
//      ~clickCalStop.();          // abort early
// ============================================================

~clickCalStop = {
    ~clickCalPrev !? {
        ~dirt.receiveAction = ~clickCalPrev;
        ~clickCalPrev = nil;
        "click calibration stopped; tempo tracking restored.".postln;
    };
};

~clickCalibrate = { |samples = 64|
    var lat, prev, n = 0;

    if (~dirt.isNil) {
        "click-calibrate: SuperDirt isn't running. Evaluate startup.scd first.".postln;
    } {
        ~clickCalStop.();                      // never wrap our own wrapper
        lat  = Array.new(samples);
        prev = ~dirt.receiveAction;
        ~clickCalPrev = prev;

        ("measuring... play a pattern in Tidal (any pattern). Need " ++ samples
            ++ " events.").postln;

        ~dirt.receiveAction = { |ev|
            prev.value(ev);                    // keep looper.scd's tempo tracking alive
            ev[\latency] !? { |l|
                if (n < samples) {
                    lat = lat.add(l);
                    n = n + 1;
                    if (n == samples) {
                        var mean, sd, sLat, anchorAhead;
                        sLat  = s.latency;
                        mean  = lat.sum / lat.size;
                        sd    = (lat.collect { |x| (x - mean).squared }.sum / lat.size).sqrt;
                        // If the grid is anchored to ev[\timeStamp], ~lastEventTime sits
                        // in the FUTURE by roughly the lookahead. Anchored to arrival, it
                        // would equal "now". That is the regression check.
                        anchorAhead = (~lastEventTime ? 0) - Main.elapsedTime;

                        "".postln;
                        "======== CLICK CALIBRATION ========".postln;
                        ("events measured   : " ++ lat.size).postln;
                        ("Tidal lookahead   : mean " ++ (mean * 1000).round(0.1) ++ " ms"
                            ++ "   (min " ++ (lat.minItem * 1000).round(0.1)
                            ++ ", max " ++ (lat.maxItem * 1000).round(0.1)
                            ++ ", sd " ++ (sd * 1000).round(0.1) ++ ")").postln;
                        ("s.latency         : " ++ (sLat * 1000).round(0.1) ++ " ms").postln;
                        "".postln;
                        ("grid anchor is " ++ (anchorAhead * 1000).round(0.1)
                            ++ " ms ahead of now").postln;
                        if (anchorAhead > (mean * 0.5)) {
                            "  OK — anchored to when events SOUND (ev[\\timeStamp]).".postln;
                            "  The lookahead is already compensated, so:".postln;
                            ("    ideal ~clickOffset = 0        (yours: " ++ ~clickOffset ++ ")").postln;
                            if (~clickOffset.abs > 0.005) {
                                "  Yours is non-zero — that is taste, or a hint something else is off.".postln;
                            };
                        } {
                            "  *** REGRESSED — the grid is anchored to message ARRIVAL. ***".postln;
                            ("  *** Recordings will start ~" ++ (mean * 1000).round(0.1)
                                ++ " ms early and leave a hole at the punch-in point.").postln;
                            "  *** Check ~dirt.receiveAction in looper.scd. ***".postln;
                        };
                        "".postln;
                        // NOT the same story for loops. The record head and play head
                        // share ONE Phasor, so moving the record start moves both: a note
                        // captured at buffer position p is replayed at T_start + p + k*D,
                        // which stays D-periodic from its capture whatever T_start was.
                        // The shift cancels, so ~loopOffset does essentially nothing for
                        // alignment. The real loop error is the interface round trip, and
                        // fixing that needs the READ head offset from the WRITE head.
                        ("~loopOffset (" ++ ~loopOffset ++ ") is still NOT a timing knob for loops —").postln;
                        "  record and play share one Phasor, so shifting the start cancels out.".postln;
                        "  A loop's real error is the ADC->DAC round trip (see the 'Latency".postln;
                        "  (in/out)' line in the boot log); compensating it needs a read-head".postln;
                        "  offset, not this. Leave ~loopOffset at 0 unless you want the loop".postln;
                        "  BOUNDARY to sit somewhere else in the bar.".postln;
                        if (sd > 0.02) {
                            "NOTE: lookahead is jittery (sd > 20 ms) — Tidal sends events in".postln;
                            "      frames, so a single number can only ever be a best fit.".postln;
                        };
                        "==================================".postln;
                        "".postln;
                        ~clickCalStop.();
                    };
                };
            };
        };
    };
};

"tools/click-calibrate.scd loaded — run:  ~clickCalibrate.();  (with Tidal playing)".postln;
