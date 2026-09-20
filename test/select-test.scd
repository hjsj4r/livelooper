// ============================================================
//  LIVE LOOPER · select-test.scd
//  Three things added together, because they interlock:
//
//    PINS      the selection is (pinned tracks + the focused one), no mode
//    STOP/START  silence a loop and bring it back on a bar line, keeping its phase
//    SETTINGS  config values edited live, and written back to config.scd
//
//  The settings section writes to a COPY of config.scd in a temp directory, never to
//  the real one — a test that rewrites your rig's config would be a bad trade.
//
//  Run it headless (no ZOOM H8, no controller):
//    & "C:\Program Files\SuperCollider-3.14.1\sclang.exe" -D d:/livelooper/test/select-test.scd
//
//  Expect: "65 passed, 0 failed".
// ============================================================
(
var pass = 0, fail = 0, ok, t, sandbox, original;

ok = { |label, cond|
    if (cond) { pass = pass + 1; ("  PASS  " ++ label).postln }
             { fail = fail + 1; ("  FAIL  " ++ label).postln };
};

s = Server(\llSelTest, NetAddr("127.0.0.1", 57161));
Server.default = s;
s.options.device = nil;
s.options.numInputBusChannels  = 12;
s.options.numOutputBusChannels = 2;
s.options.memSize = 8192 * 16;

s.waitForBoot({
    fork {
        1.0.wait;
        "D:/livelooper/config.scd".load;
        // a session starts with no tracks, so the test brings its own layout
        ~trackInputs = [9, 8, 5, [4, 7], 6];
        ~trackNames  = ["a", "b", "c", "pair", "e"];
        ~dirtPort = NetAddr.langPort;
        ~dirt = SuperDirt(2, s); ~dirt.start(~dirtPort, [0, 0]);
        1.0.wait;
        ["looper.scd", "click.scd", "settings.scd"].do { |f|
            ("D:/livelooper/" ++ f).load;
        };
        // THE CLOCK IS DRIVEN BY HAND BELOW, so refuse live events: this SuperDirt
        // listens on sclang's own port, which is 57120 when it is free — the port a
        // running Tidal sends to. One stray event sets ~lastCycle to that session's
        // cycle counter (seen: 876) and every timing assertion here then measures the
        // wrong phrase. panic-test keeps receiveAction on purpose; it tests it.
        ~dirt.receiveAction = nil;
        while { ~tracks.isNil or: { ~tracks.any { |x| x[\synth].isNil } } } { 0.2.wait };
        ~cps = 2.0; ~lastCycle = 0; ~lastEventTime = Main.elapsedTime;

        "".postln; "--- PINS: SELECTION IS PINNED + FOCUSED ---".postln;
        ~pinClear.();
        ~navFocus.(2);
        ok.("bare selection is just the focus", ~selection.() == [2]);
        ~pinToggle.();
        ok.("pinning the focus does not double it", ~selection.() == [2]);
        ok.("...and it is recorded as pinned",     ~pinned == [2]);
        // the point of pinning: navigating away must NOT drop it
        ~navFocus.(4);
        ok.("navigating away keeps the pin",  ~selection.() == [2, 4]);
        ~pinToggle.();
        ~navFocus.(0);
        ok.("two pins plus a focus", ~selection.() == [0, 2, 4]);
        ok.("selection is always sorted",
            ~selection.() == ~selection.().sort);
        // pinning is a toggle
        ~navFocus.(2);
        ~pinToggle.();
        ~navFocus.(0);
        ok.("unpinning removes it",  ~selection.() == [0, 4]);
        ~pinClear.();
        ok.("pinClear empties it",   ~selection.() == [0]);

        // a pin on a mixer level has no meaning
        ~navFocus.(~tracks.size);
        ~pinToggle.();
        ok.("a mixer level cannot be pinned", ~pinned.isEmpty);
        ok.("...and selects no track",        ~selection.().isEmpty);
        ~navFocus.(0);

        "".postln; "--- TRANSPORT ACTS ON THE SELECTION ---".postln;
        ~navFocus.(1); ~pinToggle.();
        ~navFocus.(3);
        ok.("selection is 1 and 3", ~selection.() == [1, 3]);
        ~selDo.("record", { |x| ~trackRecord.(x) });
        0.4.wait;
        ok.("both selected tracks record",
            ~tracks[1][\state] == \recording and: { ~tracks[3][\state] == \recording });
        ok.("unselected tracks untouched",
            ~tracks[0][\state] == \idle and: { ~tracks[2][\state] == \idle });
        ~selDo.("clear", { |x| ~trackClear.(x) });
        0.3.wait;
        ok.("both clear",
            ~tracks[1][\state] == \idle and: { ~tracks[3][\state] == \idle });
        // the LEVEL deliberately follows the focus alone, not the selection
        ~trackLevel.(~tracks[1], 1.0); ~trackLevel.(~tracks[3], 1.0);
        ~navAdjust.(-0.5);
        ok.("level moves only the focused track",
            (~tracks[3][\level] - 0.5).abs < 0.001 and: { ~tracks[1][\level] == 1.0 });
        ~trackLevel.(~tracks[3], 1.0);
        ~pinClear.();

        // a stale pin must never point at a track that no longer exists
        ~pinned = [0, 99];
        ~navFocus.(0);
        ok.("out-of-range pins are filtered out", ~selection.() == [0]);
        ~pinClear.();

        "".postln; "--- STOP / START ON THE GRID ---".postln;
        t = ~tracks[0];
        ok.("stop/start on an empty track is ignored",
            { ~trackLoopToggle.(t); t[\state] == \idle }.value);
        ~trackRecord.(t);
        3.0.wait;                        // punch-in + 2 s take + tail
        ok.("recorded and playing", t[\state] == \playing);

        ~trackLoopToggle.(t);
        ok.("stop is ARMED, not immediate", t[\state] == \stopping);
        ok.("still audible until the bar line", t[\state] != \stopped);
        1.2.wait;                        // past the next bar at cps 2
        ok.("stopped on the bar line", t[\state] == \stopped);
        ok.("the buffer is untouched",  t[\buf].notNil);

        ~trackLoopToggle.(t);
        ok.("start is armed",  t[\state] == \starting);
        1.2.wait;
        ok.("playing again",   t[\state] == \playing);

        // pressing twice before the bar line cancels rather than queueing
        ~trackLoopToggle.(t);
        ok.("armed to stop",   t[\state] == \stopping);
        ~trackLoopToggle.(t);
        ok.("second press cancels it", t[\state] == \starting);
        1.2.wait;
        ok.("...and it never went silent", t[\state] == \playing);

        // record must cancel a pending toggle, or it would mute the new take
        ~trackLoopToggle.(t);
        ok.("armed to stop again", t[\state] == \stopping);
        ~trackRecord.(t);
        ok.("record takes over",   t[\state] == \recording);
        3.0.wait;
        ok.("the pending stop did NOT fire", t[\state] == \playing);
        ~trackClear.(t);
        0.3.wait;

        "".postln; "--- SETTINGS ---".postln;
        ok.("every entry has a key",   ~settingsSpec.every { |e| e[\key].notNil });
        ok.("every entry has a range", ~settingsSpec.every { |e|
            e[\min].notNil and: { e[\max].notNil } and: { e[\max] > e[\min] } });
        // .any, not .includes: Array.includes compares by IDENTITY, so a list of
        // Strings never matches an equal String. That has cost this project a whole
        // evening once already (ServerOptions.devices).
        ok.("every entry says when it bites", ~settingsSpec.every { |e|
            #["now", "beat", "record"].any { |w| w == e[\when] } });
        ok.("keys are unique",
            ~settingsSpec.collect({ |e| e[\key] }).asSet.size == ~settingsSpec.size);
        // nothing that needs a rebuild may be offered as a live slider
        ok.("no restart-only keys are exposed", ~settingsSpec.every { |e|
            #[\audioDevice, \sampleRate, \numInputs, \numOutputs, \trackInputs,
              \minCps, \maxLoopCycles, \dirtPort, \dashPort].includes(e[\key]).not });

        ~settingsSet.("tailSecs", 0.42);
        ok.("set writes the variable",  (~tailSecs - 0.42).abs < 0.0001);
        ok.("...and marks it dirty",    ~settingsDirty.any { |k| k == \tailSecs });
        ~settingsSet.("tailSecs", 99);
        ok.("out of range is clamped",  ~tailSecs == 1.5);
        ~settingsSet.("tailSecs", -5);
        ok.("clamped at the bottom",    ~tailSecs == 0);
        ~settingsSet.("clickDiv", 3.7);
        ok.("integer steps stay integer", ~clickDiv == 4);
        ok.("unknown keys are ignored", ~settingsSet.("nonsense", 1).isNil);

        // "now" values must reach the running synths, not just the variable
        ~settingsSet.("monLevel", 0.25);
        ok.("a live value is applied",  (~monLevel - 0.25).abs < 0.0001);

        "".postln; "--- NUMBER FORMATTING ---".postln;
        // what gets written into config.scd has to read like something a person typed
        ok.("0.029 stays 0.029", ~settingsFormat.(0.029, 0.001) == "0.029");
        ok.("0.003 stays 0.003", ~settingsFormat.(0.003, 0.001) == "0.003");
        ok.("integers have no point", ~settingsFormat.(4.0, 1) == "4");
        ok.("0.5 at step 0.01",  ~settingsFormat.(0.5, 0.01) == "0.5");
        ok.("no float noise",
            ~settingsFormat.(0.1 + 0.2, 0.01).asFloat == 0.3);
        ok.("negatives survive", ~settingsFormat.(-0.012, 0.001).asFloat == -0.012);

        "".postln; "--- SAVING TO A CONFIG FILE ---".postln;
        // sandbox: a copy of the real config, so this test can never damage the rig
        sandbox  = (Platform.defaultTempDir ++ "ll-settings-test/").standardizePath;
        File.mkdir(sandbox);
        original = File.readAllString("D:/livelooper/config.scd");
        File(sandbox ++ "config.scd", "w").write(original).close;
        ~projectDir = sandbox;
        ok.("sandbox points away from the project",
            ~settingsPath.().find("livelooper/config.scd").isNil);

        ~settingsSet.("tailSecs",   0.75);
        ~settingsSet.("loopOffset", 0.031);
        ~settingsSet.("clickDiv",   3);
        ok.("three values are dirty", ~settingsDirty.size >= 3);
        ~settingsSave.();
        ok.("dirty list is cleared by saving", ~settingsDirty.isEmpty);

        {
            var after = File.readAllString(sandbox ++ "config.scd");
            var lines = after.split($\n);
            var lineFor = { |k|
                lines.detect { |l| ~settingsIsAssign.(l, k) };
            };
            ok.("tailSecs was written",   lineFor.(\tailSecs).contains("0.75"));
            ok.("loopOffset was written", lineFor.(\loopOffset).contains("0.031"));
            ok.("clickDiv was written",   lineFor.(\clickDiv).contains("3"));
            // and, far more important, that nothing ELSE moved
            ok.("line count is unchanged",
                lines.size == original.split($\n).size);
            ok.("comments survived",
                after.contains("// ── Loop join: head fade + tail"));
            ok.("the ladder comments survived",
                after.contains("covers a crash or a big reverb"));
            ok.("trailing comments survived",
                lineFor.(\clickDiv).contains("clicks per cycle"));
            ok.("a backup was written",
                File.exists(sandbox ++ "config.scd.bak"));
            ok.("the backup is the ORIGINAL",
                File.readAllString(sandbox ++ "config.scd.bak") == original);
            // ~tailSecs and ~tailCurve share a prefix — a sloppy match would hit both
            ok.("prefix keys are not confused",
                lineFor.(\tailCurve).contains("~tailCurve"));
            ok.("a comment mentioning a key is not treated as its assignment",
                ~settingsIsAssign.("// ~tailSecs is read at record time", \tailSecs).not);

            // reloading the sandbox file must give back exactly what we saved
            ~tailSecs = 0; ~loopOffset = 0;
            ~settingsReload.();
            ok.("reload restores tailSecs",   (~tailSecs - 0.75).abs < 0.0001);
            ok.("reload restores loopOffset", (~loopOffset - 0.031).abs < 0.0001);
            ok.("reload clears dirty",        ~settingsDirty.isEmpty);

            "".postln;
            ("======== " ++ pass ++ " passed, " ++ fail ++ " failed ========").postln;
            fork { 0.5.wait; 0.exit };
        }.value;
    };
});
)
