// ============================================================
//  LIVE LOOPER · tools/click-calibrate.scd
//  Works out ~clickOffset from measurement instead of by ear.
//
//  WHY AN OFFSET IS NEEDED AT ALL
//  Tidal sends each event AHEAD of when it should sound, timestamped with its intended
//  sounding time. sclang hands that message over immediately (verified: a bundle sent
//  0.3 s ahead arrives now, with time = now + 0.3). But looper.scd anchors the beat grid
//  with  ~lastEventTime = Main.elapsedTime  — the moment we HEARD about the event, not
//  the moment it SOUNDS. So every beat we compute is early by exactly that lookahead,
//  which SuperDirt already measures for us as ev[\latency].
//
//  The click then goes out with s.makeBundle(s.latency, ...), delaying it further. So:
//
//      click sounds at : beat - latency + ~clickOffset + s.latency
//      wanted          : beat
//      =>  ~clickOffset = mean(latency) - s.latency
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
                        var mean, sd, ideal, delta, sLat, idealLoop;
                        sLat  = s.latency;
                        mean  = lat.sum / lat.size;
                        sd    = (lat.collect { |x| (x - mean).squared }.sum / lat.size).sqrt;
                        ideal = mean - sLat;
                        delta = ideal - ~clickOffset;
                        // Loops start via s.makeBundle(0, ...) — no s.latency added — so
                        // they need the full lookahead, not lookahead - s.latency.
                        idealLoop = mean;

                        "".postln;
                        "======== CLICK CALIBRATION ========".postln;
                        ("events measured   : " ++ lat.size).postln;
                        ("Tidal lookahead   : mean " ++ (mean * 1000).round(0.1) ++ " ms"
                            ++ "   (min " ++ (lat.minItem * 1000).round(0.1)
                            ++ ", max " ++ (lat.maxItem * 1000).round(0.1)
                            ++ ", sd " ++ (sd * 1000).round(0.1) ++ ")").postln;
                        ("s.latency         : " ++ (sLat * 1000).round(0.1) ++ " ms").postln;
                        "".postln;
                        ("current ~clickOffset : " ++ ~clickOffset).postln;
                        ("ideal   ~clickOffset : " ++ ideal.round(0.001)
                            ++ "   (lookahead - s.latency)").postln;
                        ("difference           : " ++ (delta * 1000).round(0.1) ++ " ms"
                            ++ if (delta.abs < 0.005) { "   <- already within a few ms" }
                                                     { "   <- worth changing" }).postln;
                        "".postln;
                        "Try it live (takes effect on the very next beat):".postln;
                        ("    ~clickOffset = " ++ ideal.round(0.001) ++ ";").postln;
                        "If that sounds right, write it into config.scd.".postln;
                        "".postln;
                        // NOT the same story for loops. The record head and play head
                        // share ONE Phasor, so moving the record start moves both: a note
                        // captured at buffer position p is replayed at T_start + p + k*D,
                        // which stays D-periodic from its capture whatever T_start was.
                        // The shift cancels, so ~loopOffset does essentially nothing for
                        // alignment. The real loop error is the interface round trip, and
                        // fixing that needs the READ head offset from the WRITE head.
                        ("~loopOffset (" ++ ~loopOffset ++ ") is NOT the equivalent knob for loops —").postln;
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
