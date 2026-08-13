// ============================================================
//  LIVE LOOPER · tools/input-scan.scd
//  Which SuperCollider input index is that physical H8 jack?
//
//  The H8's ASIO channel order is not a sequence and the project's comments have
//  disagreed about it, so map jacks rather than assuming. Safe to run mid-session: it
//  only listens, it never outputs audio.
//
//  GUIDED MAPPING (what you want for setting up ~trackInputs):
//      "D:/livelooper/tools/input-scan.scd".load;
//      ~mapInput.("mic");        // then play into that jack while it listens
//      ~mapInput.("guitar");
//      ~mapInput.("synth");
//      ~inputMapShow.();         // prints a paste-ready ~trackInputs line
//
//  It accepts an answer only when one channel (or one clear PAIR, for a stereo mic)
//  dominates. Bleed between inputs is normal and is exactly what makes a naive
//  "loudest channel" reading useless, so ambiguous results are rejected rather than
//  guessed at.
//
//  FREE MONITORING (just watch levels):
//      ~inputScanStart.();  ~inputScanStop.();
// ============================================================

// Live monitoring threshold. 0.05 rather than 0.01: below that you are looking at hum
// and bleed, not at someone playing.
~inputScanThresh = 0.05;
~inputScanQuiet  = false;

SynthDef(\inputScan, {
    var n   = s.options.numInputBusChannels;
    var sig = SoundIn.ar((0 .. (n - 1)));
    SendReply.kr(Impulse.kr(20), '/inLevels', Amplitude.kr(sig, 0.01, 0.2));
}).add;

~inputScanStop = {
    ~inputScanSynth !? { ~inputScanSynth.free; ~inputScanSynth = nil };
    [\inLevels, \inMap].do { |k| OSCdef.all[k] !? { |d| d.free } };
    "input scan stopped.".postln;
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
        "Guided mapping:  ~mapInput.(\"mic\")   then  ~inputMapShow.()".postln;
        "Stop with:       ~inputScanStop.()".postln;
    };
};

// ── Guided mapping ──────────────────────────────────────────
~inputMap      = ~inputMap ? List.new;
~inputMapClear = { ~inputMap = List.new; "input map cleared.".postln };

~inputMapReport = { |name, peaks|
    var order, p1, p2, p3, i1, i2, result = nil;
    order = (0 .. (peaks.size - 1)).asArray.sort { |a, b| peaks[a] > peaks[b] };
    i1 = order[0]; i2 = order[1];
    p1 = peaks[i1]; p2 = peaks[i2]; p3 = peaks[order[2]];

    "".postln;
    ("  levels: " ++ order.keep(4).collect { |c| c.asString ++ ":" ++ peaks[c].round(0.001) }
        .join("   ")).postln;

    case
    { p1 < 0.08 } {
        ("  TOO QUIET (peak " ++ p1.round(0.001)
            ++ ") — play louder, or raise the H8's gain, and try again.").postln;
    }
    // a stereo mic drives two channels together: both far above the rest, and within
    // about 2:1 of each other
    { (p2 > (p1 * 0.4)) and: { p3 < (p2 * 0.35) } } {
        result = [i1, i2].sort;
        ("  -> STEREO PAIR " ++ result ++ "   (two channels together, rest much quieter)")
            .postln;
    }
    // one channel clearly dominant
    { p2 < (p1 * 0.35) } {
        result = i1;
        ("  -> MONO channel " ++ i1).postln;
    }
    {
        "  AMBIGUOUS — several channels are similarly loud. That usually means bleed".postln;
        "  between H8 inputs. Play louder into just this jack, or turn the others down,".postln;
        "  then run ~mapInput again.".postln;
    };

    result !? {
        ~inputMap = ~inputMap.reject { |e| e[0] == name };   // remapping replaces
        ~inputMap.add([name, result]);
        ("  recorded '" ++ name ++ "' = " ++ result).postln;
    };
    "".postln;
};

~mapInput = { |name = "input", secs = 4|
    var n, peaks;
    if (~inputScanSynth.isNil) {
        "~mapInput: run ~inputScanStart.() first (or re-load this file).".postln;
    } {
        n     = s.options.numInputBusChannels;
        peaks = Array.fill(n, 0);
        OSCdef(\inMap, { |msg|
            msg[3..].do { |v, i| peaks[i] = max(peaks[i], v) };
        }, '/inLevels');
        fork {
            ~inputScanQuiet = true;                 // don't bury the result in HOT lines
            ("").postln;
            (">>> PLAY INTO '" ++ name ++ "' NOW — listening for " ++ secs ++ "s").postln;
            secs.wait;
            OSCdef.all[\inMap] !? { |d| d.free };
            ~inputScanQuiet = false;
            ~inputMapReport.(name, peaks);
        };
    };
};

~inputMapShow = {
    "".postln;
    "======== INPUT MAP ========".postln;
    if (~inputMap.isEmpty) {
        "  nothing mapped yet — use ~mapInput.(\"name\")".postln;
    } {
        ~inputMap.do { |e| ("  " ++ e[0].asString.padRight(16) ++ e[1]).postln };
        "".postln;
        "  Paste into config.scd (order = track order):".postln;
        ("    ~trackInputs = ["
            ++ ~inputMap.collect { |e| e[1].asCompileString }.join(", ") ++ "];").postln;
    };
    "===========================".postln;
    "".postln;
};

~inputScanStart.();
