// ============================================================
//  LIVE LOOPER  ·  settings.scd
//  The config values worth reaching for mid-soundcheck, exposed to the dashboard.
//  Loaded by startup.scd, before dashboard.scd.
//
//  WHAT IS AND IS NOT HERE
//  Only values that can change in a RUNNING rig. Anything that decides how the server or
//  the tracks were built — audio device, sample rate, channel counts, ~trackInputs,
//  ~minCps, ~maxLoopCycles, ports — is deliberately absent: changing those means
//  rebuilding buffers and synths, which is a restart, and a slider that silently did
//  nothing would be worse than no slider.
//
//  WHEN A CHANGE BITES
//  Three kinds, and the dashboard says which is which:
//    now      pushed straight to the running synths
//    beat     read live on the next beat
//    record   read when you next hit RECORD, so re-record to hear it
//
//  SAVING
//  Editing here changes the SESSION. ~settingsSave writes the values back into
//  config.scd, rewriting only the number on each assignment line and leaving every
//  comment, blank line and bit of alignment exactly where it was. Nothing touches the
//  disk until you ask for it, so soundcheck experiments cost nothing.
// ============================================================

~settingsPath = { (~projectDir ? "D:/livelooper/") ++ "config.scd" };

// Keys changed in this session and not yet written to the file. Survives a reload of
// this file so that re-evaluating does not silently "clean" a dirty setting.
~settingsDirty = ~settingsDirty ? [];

// Push a value to things already running. Values with no `apply` are read where they are
// needed (at record time, or on the next beat), so they need nothing here.
~settingsSpec = [
    (key: \loopOffset, label: "loop offset", min: 0, max: 0.08, step: 0.001,
        when: "record", note: "audio round trip. Measure it: tools/latency-measure.scd"),
    (key: \headFadeSecs, label: "head fade", min: 0, max: 0.02, step: 0.001,
        when: "record", note: "de-clicks the seam. Above ~10ms it softens attacks"),
    (key: \tailSecs, label: "tail", min: 0, max: 1.5, step: 0.01,
        when: "record", note: "carries a cymbal across the join. 0 = butt splice"),
    (key: \tailCurve, label: "tail curve", min: 0.2, max: 2.0, step: 0.05,
        when: "record", note: "below 1 holds the tail high early, keeping the decay natural"),
    (key: \recordQuantize, label: "record quantize", min: 1, max: 4, step: 1,
        when: "record", note: "bars a take may start on. 1 = the next measure"),
    (key: \numLoopCycles, label: "default bars", min: 1, max: 8, step: 1,
        when: "record", note: "length of a NEW loop. Per-track length is on the strips"),
    (key: \monLevel, label: "input monitor", min: 0, max: 1, step: 0.01,
        when: "now", note: "live input through SC. 0 if you monitor direct on the H8",
        apply: { |v| (~tracks ? []).do { |t| t[\synth] !? { t[\synth].set(\monLevel, v) } } }),
    (key: \clickDiv, label: "click division", min: 1, max: 8, step: 1,
        when: "beat", note: "clicks per bar. 4 = quarter notes in 4/4"),
    (key: \clickOffset, label: "click offset", min: -0.05, max: 0.05, step: 0.001,
        when: "beat", note: "click vs the patterns ONLY. Never use this for latency"),
    (key: \fxPreHighpass, label: "drive highpass", min: 40, max: 400, step: 5,
        when: "now", note: "lows rolled off before the clipper. Higher = tighter",
        apply: { |v| (~tracks ? []).do { |t| t[\fxSynth] !? { t[\fxSynth].set(\preHighpass, v) } } }),
    (key: \fxTone, label: "drive tone", min: 0, max: 1, step: 0.01,
        when: "now", note: "post-clip brightness, 0 = dark .. 1 = fizzy",
        apply: { |v| (~tracks ? []).do { |t| t[\fxSynth] !? { t[\fxSynth].set(\tone, v) } } }),
    (key: \fxDriveMax, label: "drive max", min: 0, max: 1, step: 0.01,
        when: "now", note: "how far R2 can push the drive",
        apply: { (~tracks ? []).do { |t| ~trackFxRescale.(t) } }),
];

~settingsFind = { |key| ~settingsSpec.detect { |e| e[\key] == key.asSymbol } };

// Integers stay integers and floats print at the precision their own step implies, so a
// value written back to config.scd reads the way a person would have typed it — never
// 0.30000000000000004.
~settingsFormat = { |v, step|
    if (step >= 1) {
        v.round.asInteger.asString;
    } {
        var places = step.log10.neg.roundUp.asInteger;
        var scaled = (v / step).round * step;
        var s = scaled.round(10 ** places.neg).asString;
        // asString can still hand back exponent form or a long tail; rebuild from the
        // integer if so, which cannot drift
        if (s.includes($e) or: { s.size > (places + 8) }) {
            var n = (v / (10 ** places.neg)).round.asInteger;
            var sign = if (n < 0) { "-" } { "" };
            var digits = n.abs.asString.padLeft(places + 1, "0");
            s = sign ++ digits[0 .. digits.size - places - 1] ++ "."
                ++ digits[digits.size - places .. ];
        };
        s;
    };
};

~settingsGet = { |key|
    var e = ~settingsFind.(key);
    e !? { (currentEnvironment[e[\key]] ? 0).asFloat };
};

// Clamped to the spec, so a malformed message from the browser cannot put the rig into a
// state you have no slider to get out of.
~settingsSet = { |key, value|
    var e = ~settingsFind.(key);
    e !? {
        var v = value.asFloat.clip(e[\min], e[\max]);
        if (e[\step] >= 1) { v = v.round(e[\step]) };
        currentEnvironment[e[\key]] = v;
        e[\apply] !? { e[\apply].value(v) };
        if (~settingsDirty.any { |k| k == e[\key] }.not) {
            ~settingsDirty = ~settingsDirty ++ [e[\key]];
        };
        v;
    };
};

// ── Writing back to config.scd ──────────────────────────────
// Line-surgical on purpose. Regenerating config.scd from the spec would throw away every
// comment in it, and those comments are most of that file's value — the ladders, the
// measurements, the reasons. So each assignment line keeps everything to the left of its
// `=` and everything from its `;` onward, and only the number between them is replaced.
~settingsRewrite = { |line, value|
    var eq = line.indexOf($=);
    var semi;
    if (eq.isNil) { line } {
        semi = (eq + 1 .. line.size - 1).detect { |i| line[i] == $; };
        if (semi.isNil) { line } {
            line[0 .. eq] ++ " " ++ value ++ line[semi .. ];
        };
    };
};

// True when this line is the assignment for `key` — not a mention of it in a comment, and
// not a longer name that merely starts the same way (~tailSecs vs ~tailCurve).
~settingsIsAssign = { |line, key|
    var want = "~" ++ key.asString;
    var t = line.stripWhiteSpace;
    (t.beginsWith(want)) and: {
        var rest = t[want.size ..];
        (rest.size > 0) and: { "= \t".includes(rest[0]) };
    };
};

~settingsSave = {
    var path = ~settingsPath.();
    var text, lines, written = [], missing = [], f;
    if (File.exists(path).not) {
        ("settings: no config at " ++ path).warn;
        nil;
    } {
        text  = File.readAllString(path);
        lines = text.split($\n);
        ~settingsSpec.do { |e|
            var key = e[\key];
            var idx = (0 .. lines.size - 1).detect { |i| ~settingsIsAssign.(lines[i], key) };
            if (idx.isNil) {
                missing = missing ++ [key];
            } {
                lines[idx] = ~settingsRewrite.(lines[idx],
                    ~settingsFormat.(currentEnvironment[key] ? 0, e[\step]));
                written = written ++ [key];
            };
        };
        // A backup before every write. This file is hand-edited and full of comments;
        // one bad write with no way back would be a genuinely bad afternoon.
        f = File(path ++ ".bak", "w"); f.write(text); f.close;
        f = File(path, "w"); f.write(lines.join("\n")); f.close;
        ~settingsDirty = [];
        ("settings: wrote " ++ written.size ++ " values to config.scd"
            ++ " (previous version kept as config.scd.bak)").postln;
        if (missing.notEmpty) {
            ("settings: no assignment line found for " ++ missing
                ++ " — those were NOT saved").warn;
        };
        written.size;
    };
};

// Re-read config.scd and push everything live. Note this reloads the WHOLE file, so
// runtime values that happen to live there too (~clickAmp) go back to their written
// defaults — which is what "reload from file" ought to mean.
~settingsReload = {
    ~settingsPath.().load;
    ~settingsSpec.do { |e| e[\apply] !? { e[\apply].value(currentEnvironment[e[\key]]) } };
    ~settingsDirty = [];
    "settings: reloaded from config.scd".postln;
    ~settingsSpec.size;
};

("=== settings.scd loaded — " ++ ~settingsSpec.size ++ " values editable from the dashboard"
    ++ if (~settingsDirty.notEmpty) { ", " ++ ~settingsDirty.size ++ " unsaved" } { "" }
    ++ " ===").postln;
