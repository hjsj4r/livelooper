// ============================================================
//  LIVE LOOPER · tools/input-scan.scd
//  Which SuperCollider input index is that physical H8 jack?
//
//  The H8 exposes discrete inputs AND channels carrying the whole mix, so playing one
//  instrument lights up several channels — the jack plus every mix channel it feeds.
//  Loudness alone cannot tell those apart.
//
//  What CAN: a mix channel is active for EVERY instrument, a discrete input for exactly
//  ONE. So record a pass per instrument, then cross-reference. Channels common to all
//  passes are mix; channels exclusive to a pass are that instrument's input, and two
//  exclusive channels mean a stereo pair.
//
//  USAGE — one pass per source, playing only that source each time:
//      "D:/livelooper/tools/input-scan.scd".load;
//      ~mapInput.("mic");        // play the stereo mic
//      ~mapInput.("guitar");
//      ~mapInput.("synth");
//      ~inputMapShow.();         // cross-references and prints ~trackInputs
//
//  Needs at least TWO passes — with one there is nothing to compare against. Re-running
//  ~mapInput with the same name replaces that pass.
//
//  Safe to run mid-session: it only listens, it never outputs audio.
// ============================================================

~inputScanThresh = 0.05;      // live monitor only; the analysis is relative, not absolute
~inputScanQuiet  = false;

SynthDef(\inputScan, {
    var n   = s.options.numInputBusChannels;
    var sig = SoundIn.ar((0 .. (n - 1)));
    SendReply.kr(Impulse.kr(20), '/inLevels', Amplitude.kr(sig, 0.01, 0.2));
}).add;

~inputScanStop = {
    ~inputScanSynth !? { ~inputScanSynth.free; ~inputScanSynth = nil };
    [\inLevels, \inMap].do { |k| OSCdef.all[k] !? { |d| d.free } };
    "input scan stopped. (~inputMapShow.() still works)".postln;
};

~inputScanStart = {
    ~inputScanStop.();
    OSCdef(\inLevels, { |msg|
        var levels = msg[3..];
        var peak   = levels.maxItem;
        if (~inputScanQuiet.not and: { peak > ~inputScanThresh }) {
            ("HOT -> SC input channel " ++ levels.indexOf(peak)
                ++ "   peak " ++ peak.round(0.001)).postln;
        };
    }, '/inLevels');
    fork {
        s.sync;
        ~inputScanSynth = Synth(\inputScan, addAction: \addToTail);
        "".postln;
        "=== INPUT SCAN ===".postln;
        ("scanning " ++ s.options.numInputBusChannels ++ " channels.").postln;
        "One pass per source:  ~mapInput.(\"mic\")  ~mapInput.(\"guitar\")  ...".postln;
        "Then:                 ~inputMapShow.()".postln;
        "Stop with:            ~inputScanStop.()".postln;
    };
};

// ── Passes ──────────────────────────────────────────────────
// Each pass is [name, peaksPerChannel]. No verdict here — a pass means nothing until
// there is another to compare it with.
~inputPasses     = ~inputPasses ? List.new;
~inputMapClear   = { ~inputPasses = List.new; "input passes cleared.".postln };

~mapInput = { |name = "input", secs = 4|
    var peaks;
    if (~inputScanSynth.isNil) {
        "~mapInput: run ~inputScanStart.() first (or re-load this file).".postln;
    } {
        peaks = Array.fill(s.options.numInputBusChannels, 0);
        OSCdef(\inMap, { |msg|
            msg[3..].do { |v, i| peaks[i] = max(peaks[i], v) };
        }, '/inLevels');
        fork {
            ~inputScanQuiet = true;
            "".postln;
            (">>> PLAY '" ++ name ++ "' NOW — listening for " ++ secs ++ "s").postln;
            secs.wait;
            OSCdef.all[\inMap] !? { |d| d.free };
            ~inputScanQuiet = false;
            if (peaks.maxItem < 0.08) {
                ("  TOO QUIET (peak " ++ peaks.maxItem.round(0.001)
                    ++ ") — play louder or raise the H8's gain, then run it again.").postln;
            } {
                ~inputPasses = ~inputPasses.reject { |e| e[0] == name };
                ~inputPasses.add([name, peaks]);
                ("  recorded '" ++ name ++ "': "
                    ++ (0 .. (peaks.size - 1)).asArray
                        .sort { |a, b| peaks[a] > peaks[b] }.keep(5)
                        .collect { |c| c.asString ++ ":" ++ peaks[c].round(0.001) }.join("  ")
                ).postln;
                ("  " ++ ~inputPasses.size ++ " pass(es) recorded."
                    ++ if (~inputPasses.size < 2) { "  Need at least 2." } { "" }).postln;
            };
            "".postln;
        };
    };
};

// ── Cross-reference ─────────────────────────────────────────
~inputMapShow = { |activeAt = 0.25|
    var nPass, active, counts, nCh, mixCh, results;
    nPass = ~inputPasses.size;
    "".postln;
    "======== INPUT MAP ========".postln;
    if (nPass < 2) {
        ("  only " ++ nPass ++ " pass recorded — need at least 2, so mix channels can be").postln;
        "  told apart from discrete inputs. Run ~mapInput for another source.".postln;
    } {
        nCh = ~inputPasses[0][1].size;
        // A channel counts as active in a pass if it reaches activeAt of that pass's
        // own peak. Relative, so a quiet source is judged on its own terms.
        active = ~inputPasses.collect { |e|
            var pk = e[1], mx = pk.maxItem;
            (0 .. (nCh - 1)).select { |c| pk[c] > (mx * activeAt) };
        };
        counts = Array.fill(nCh, 0);
        active.do { |chans| chans.do { |c| counts[c] = counts[c] + 1 } };
        mixCh  = (0 .. (nCh - 1)).select { |c| counts[c] == nPass };

        ("  passes: " ++ nPass ++ "    channels active in ALL of them: " ++ mixCh
            ++ "  <- the H8's mix, ignored").postln;
        "".postln;

        results = ~inputPasses.collect { |e, p|
            var name  = e[0];
            var mine  = active[p].select { |c| counts[c] == 1 };   // exclusive to this pass
            var shared = active[p].select { |c| (counts[c] > 1) and: { counts[c] < nPass } };
            var spec = nil;
            case
            { mine.size == 1 } { spec = mine[0] }
            { mine.size == 2 } { spec = mine.sort }
            { mine.size == 0 } {
                ("  " ++ name.asString.padRight(14) ++ "NO exclusive channel — this source"
                    ++ " only showed up on shared/mix channels.").postln;
                "                Is its own input muted or unplugged?".postln;
            }
            {
                ("  " ++ name.asString.padRight(14) ++ mine.size
                    ++ " exclusive channels " ++ mine ++ " — expected 1 (mono) or 2 (stereo).")
                    .postln;
                "                Pick the ones you want by hand.".postln;
            };
            spec !? {
                ("  " ++ name.asString.padRight(14) ++ spec.asCompileString
                    ++ if (spec.isArray) { "   (stereo pair)" } { "   (mono)" }
                    ++ if (shared.notEmpty) { "   [also on shared " ++ shared ++ "]" } { "" }
                ).postln;
            };
            spec;
        };

        if (results.every(_.notNil)) {
            "".postln;
            "  Paste into config.scd (order = track order):".postln;
            ("    ~trackInputs = ["
                ++ results.collect { |r| r.asCompileString }.join(", ") ++ "];").postln;
        } {
            "".postln;
            "  Fix the unresolved sources above, then run ~inputMapShow.() again.".postln;
        };
    };
    "===========================".postln;
    "".postln;
};

~inputScanStart.();
