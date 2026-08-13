// ============================================================
//  LIVE LOOPER · tools/input-scan.scd
//  Which SuperCollider input index is that physical H8 jack?
//
//  The H8's ASIO channel order is not obvious and the project's comments have
//  disagreed about it. Rather than guess: run this, play into ONE jack, and read
//  the index off the post window. Whatever it prints is what goes in ~trackInputs.
//
//  Safe to run mid-session: it only listens, it never outputs audio.
//
//  Run (server already booted):   "D:/livelooper/tools/input-scan.scd".load;
//  Stop:                          ~inputScanStop.();
// ============================================================
(
SynthDef(\inputScan, {
    var n   = s.options.numInputBusChannels;
    var sig = SoundIn.ar((0 .. (n - 1)));
    SendReply.kr(Impulse.kr(8), '/inLevels', Amplitude.kr(sig, 0.01, 0.2));
}).add;

~inputScanStop = {
    ~inputScanSynth !? { ~inputScanSynth.free; ~inputScanSynth = nil };
    OSCdef.all[\inLevels] !? { |d| d.free };
    "input scan stopped. (~inputSummary.() still works)".postln;
};

// Peak seen per channel since the scan started. Mapping several jacks in one pass is far
// easier from a table than from a scrolling log.
~inputPeaks = ~inputPeaks ? Dictionary.new;
~inputScanClear = { ~inputPeaks = Dictionary.new; "input scan: cleared.".postln };

~inputSummary = {
    var rows = ~inputPeaks.keys.asArray.sort;
    "".postln;
    "======== INPUTS THAT SAW SIGNAL ========".postln;
    if (rows.isEmpty) {
        "  nothing yet — play into a jack.".postln;
    } {
        "  SC index   peak     bar".postln;
        rows.do { |ch|
            var pk = ~inputPeaks[ch];
            ("  " ++ ch.asString.padLeft(5) ++ "     " ++ pk.round(0.001).asString.padRight(7)
                ++ "  " ++ String.fill((pk * 40).round.asInteger.clip(0, 40), $#)).postln;
        };
        "".postln;
        "  Put these in ~trackInputs (config.scd). A stereo mic on two jacks".postln;
        "  becomes ONE entry, e.g. [1, 2] — the pair need not be adjacent.".postln;
    };
    "========================================".postln;
    "".postln;
};

~inputScanStart = {
    ~inputScanStop.();
    OSCdef(\inLevels, { |msg|
        var levels = msg[3..];
        var peak   = levels.maxItem;
        // only speak up when something is actually being played, so it isn't a firehose
        if (peak > 0.01) {
            var hot = levels.indexOf(peak);
            ~inputPeaks[hot] = max(~inputPeaks[hot] ? 0, peak);
            ("HOT -> SC input channel " ++ hot
                ++ "   (levels: " ++ levels.collect(_.round(0.001)) ++ ")").postln;
        };
    }, '/inLevels');
    fork {
        s.sync;
        ~inputScanSynth = Synth(\inputScan, addAction: \addToTail);
        "".postln;
        "=== INPUT SCAN ===".postln;
        ("scanning " ++ s.options.numInputBusChannels
            ++ " input channels. Play into ONE H8 jack — the printed number is the").postln;
        "index to put in ~trackInputs.   Stop with:  ~inputScanStop.()".postln;
    };
};

~inputScanStart.();
)

// Note: this is a diagnostic, so it is deliberately NOT registered on ServerTree —
// Ctrl+. removes the scanner synth and it stays gone. Re-load the file to scan again.
