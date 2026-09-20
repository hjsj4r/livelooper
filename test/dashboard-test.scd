// ============================================================
//  LIVE LOOPER · dashboard-test.scd
//  The dashboard used to push 60 messages/second forever. It should now send a clock
//  reference ~2x/second and discrete state ONLY when something actually changes.
//
//  Run it headless (does NOT need the ZOOM H8 — boots the system default device):
//    & "C:\Program Files\SuperCollider-3.14.1\sclang.exe" -D d:/livelooper/test/dashboard-test.scd
//
//  Expect: "50 passed, 0 failed".
// ============================================================
(
var pass = 0, fail = 0, ok;
var clocks = 0, states = 0, legacy = 0, levels = 0;
var lastCps, lastPhase, lastDiv, lastState, lastLevels, lastInit, lastCycles, window = 4.0;
var lastPins, lastSpec, lastConfig, lastSaved, me, sandbox;

ok = { |label, cond|
    if (cond) { pass = pass + 1; ("  PASS  " ++ label).postln }
             { fail = fail + 1; ("  FAIL  " ++ label).postln };
};

// Dedicated server + port, so this is safe to run even while your rig is booted on the
// default 57110 — and so suites run back-to-back can't collide on a lingering scsynth.
s = Server(\llDashTest, NetAddr("127.0.0.1", 57115));
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
        // Point the dashboard feed at ourselves so we can count what it emits.
        ~dashPort = NetAddr.langPort;
        ~dirtPort = NetAddr.langPort;
        ~dirt = SuperDirt(2, s);          // no sample library — irrelevant here
        ~dirt.start(~dirtPort, [0, 0]);
        1.0.wait;

        OSCdef(\dtClock, { |msg|
            clocks = clocks + 1;
            lastCps = msg[1]; lastPhase = msg[2]; lastDiv = msg[3];
        }, '/clock');
        OSCdef(\dtState,  { |msg| states = states + 1; lastState  = msg }, '/state');
        OSCdef(\dtLevels, { |msg| levels = levels + 1; lastLevels = msg }, '/levels');
        OSCdef(\dtInit,   { |msg| lastInit = msg }, '/tracksInit');
        OSCdef(\dtCycles, { |msg| lastCycles = msg }, '/cycles');
        OSCdef(\dtPins,   { |msg| lastPins   = msg }, '/pins');
        OSCdef(\dtSpec,   { |msg| lastSpec   = msg }, '/configSpec');
        OSCdef(\dtConfig, { |msg| lastConfig = msg }, '/config');
        OSCdef(\dtSaved,  { |msg| lastSaved  = msg }, '/configSaved');
        // the retired chatty addresses must not come back
        OSCdef(\dtLegacyA, { |msg| legacy = legacy + 1 }, '/tick');
        OSCdef(\dtLegacyB, { |msg| legacy = legacy + 1 }, '/trackStates');

        ["looper.scd", "click.scd", "settings.scd", "dashboard.scd"].do { |f|
            ("D:/livelooper/" ++ f).load;
        };
        while { ~tracks.isNil or: { ~tracks.any { |x| x[\synth].isNil } } } { 0.2.wait };
        2.0.wait;                          // let the initial burst settle

        "".postln; "--- IDLE TRAFFIC ---".postln;
        clocks = 0; states = 0; legacy = 0;
        window.wait;                       // nothing is changing during this window
        ("        (" ++ clocks ++ " clock + " ++ states ++ " state messages in "
            ++ window ++ "s; the old design would have sent "
            ++ (window * 60).asInteger ++ ")").postln;
        ok.("clock arrives ~2x/second",   clocks.inclusivelyBetween(5, 12));
        ok.("no state churn while idle",  states == 0);
        ok.("legacy /tick gone",          legacy == 0);
        ok.("total under 15 msg/window",  (clocks + states) < 15);

        "".postln; "--- CLOCK CONTENT ---".postln;
        ok.("cps is a number",            lastCps.isNumber);
        ok.("phase within [0,1)",         (lastPhase >= 0) and: { lastPhase < 1 });
        ok.("div matches ~clickDiv",      lastDiv == ~clickDiv);

        "".postln; "--- CHANGES ARE PUSHED IMMEDIATELY ---".postln;
        states = 0;
        ~tracks[0][\state] = \recording;
        0.4.wait;
        ok.("track change pushed a /state", states > 0);
        // /state = [addr, focus, clickOn, clickAmp, dirtLevel, ...states]
        ok.("state carries every track",    lastState.size == (4 + ~tracks.size + 1));
        ok.("state reports the new value",  lastState[5].asSymbol == \recording);

        states = 0;
        ~navFocus.(2);
        0.4.wait;
        ok.("focus change pushed a /state", states > 0);
        ok.("focus value is carried",       lastState[1] == 2);

        states = 0;
        ~navMove.(1);
        0.4.wait;
        ok.("nav move pushed a /state",     states > 0);
        ok.("nav moved the selection",      lastState[1] == 3);

        // the click level is live state and must reach the dashboard too
        states = 0;
        ~clickAmp = 0.25;
        0.4.wait;
        ok.("click level pushed a /state",  states > 0);
        ok.("click level is carried",       (lastState[3] - 0.25).abs < 0.001);
        ~clickAmp = 0.5;
        0.4.wait;

        // the Tidal level rides in /state too, so the stick can move it and the
        // dashboard slider follows
        states = 0;
        ~dirtLevel = 0.6;
        0.4.wait;
        ok.("tidal level pushed a /state",  states > 0);
        ok.("tidal level is carried",       (lastState[4] - 0.6).abs < 0.001);
        ~dirtLevel = 1.0;
        0.4.wait;

        "".postln; "--- LOOP LENGTH ---".postln;
        states = 0;
        ~trackCycles.(~tracks[0], 8);
        0.4.wait;
        ok.("length change pushed /cycles", lastCycles.notNil);
        ok.("cycles carries every track",   lastCycles.size == (~tracks.size + 1));
        ok.("cycles reports the new value", lastCycles[1] == 8);
        ~trackCycles.(~tracks[0], 4);
        0.4.wait;

        "".postln; "--- FADER LEVELS ---".postln;
        // a hardware knob calls ~trackLevel; the dashboard must follow
        levels = 0;
        ~trackLevel.(~tracks[1], 0.25);
        0.4.wait;
        ok.("level change pushed /levels",  levels > 0);
        ok.("carries one value per track",  lastLevels.size == (~tracks.size + 1));
        ok.("carries the new value",        (lastLevels[2] - 0.25).abs < 0.001);
        ok.("leaves other tracks alone",    (lastLevels[1] - 1.0).abs < 0.001);

        // and must go quiet again once the knob stops moving
        levels = 0;
        2.0.wait;
        ok.("no /levels churn when still",  levels == 0);

        "".postln; "--- TRACK NAMES ---".postln;
        // /tracksInit carries name/input PAIRS, so a missing value can't shift every
        // following label onto the wrong strip
        ~sendTracks.();
        0.3.wait;
        ok.("tracksInit sends name+input pairs",
            lastInit.notNil and: { lastInit.size == (2 + (~tracks.size * 2)) });
        ok.("first pair carries track 0's name",
            lastInit[2].asString == ~tracks[0][\name].asString);
        // the SPEC, not a display label: the page sends it straight back when re-wiring,
        // so there is only one spelling of a source to keep in step
        ok.("and its source spec",
            lastInit[3].asString == ~trackSpecString.(~tracks[0]).asString);
        ok.("last pair carries the last track's name",
            lastInit[lastInit.size - 2].asString == ~tracks.last[\name].asString);

        "".postln; "--- COMMANDS OVER REAL OSC ---".postln;
        // Everything above calls the SC functions directly. This section goes through the
        // actual /cmd/... addresses, which is where a typo in the glue would live.
        me = NetAddr("127.0.0.1", NetAddr.langPort);
        // An earlier section sets a track's state by hand to prove /state is pushed.
        // Clear everything first, or these assertions inherit that fiction.
        ~tracks.do { |x| ~trackClear.(x) };
        0.3.wait;

        ~pinClear.(); ~navFocus.(0);
        me.sendMsg('/cmd/pinToggle', 2);
        0.3.wait;
        ok.("pinToggle over OSC pins a track", ~pinned == [2]);
        ok.("a /pins message went out",        lastPins.notNil);
        ok.("pins carry a flag per track",     lastPins.size == (~tracks.size + 1));
        ok.("the right track is flagged",      lastPins[3] == 1 and: { lastPins[1] == 0 });
        me.sendMsg('/cmd/pinToggle', 2);
        0.3.wait;
        ok.("...and unpins it",                ~pinned.isEmpty);

        // the controller's transport must act on the SELECTION, the strips on one track
        ~navFocus.(1);
        me.sendMsg('/cmd/pinToggle', 4);
        0.3.wait;
        me.sendMsg('/cmd/selRecord');
        0.4.wait;
        ok.("selRecord hits every selected track",
            ~tracks[1][\state] == \recording and: { ~tracks[4][\state] == \recording });
        ok.("...and nothing else",  ~tracks[0][\state] == \idle);
        me.sendMsg('/cmd/selClear');
        0.4.wait;
        ok.("selClear releases them",
            ~tracks.every { |x| x[\state] == \idle });
        ~pinClear.(); ~navFocus.(0);

        me.sendMsg('/cmd/selLoopToggle');
        0.4.wait;
        ok.("selLoopToggle on an empty track is harmless",
            ~tracks[0][\state] == \idle);

        "".postln; "--- SETTINGS OVER REAL OSC ---".postln;
        me.sendMsg('/cmd/getConfig');
        0.4.wait;
        ok.("configSpec arrives",       lastSpec.notNil);
        ok.("spec is 7 fields per entry",
            ((lastSpec.size - 1) % 7) == 0);
        ok.("spec covers every setting",
            ((lastSpec.size - 1) / 7) == ~settingsSpec.size);
        ok.("config values arrive",     lastConfig.notNil);
        // /config leads with how many LAYOUT keys (device, tracks) are unsaved — they
        // have no slider row, but the Save button counts them — then 3 fields per value
        ok.("config leads with the layout's unsaved count", lastConfig[1].isNumber);
        ok.("values are 3 fields each", ((lastConfig.size - 2) % 3) == 0);

        me.sendMsg('/cmd/setConfig', "tailSecs", 0.33);
        0.4.wait;
        ok.("setConfig over OSC moves the value", (~tailSecs - 0.33).abs < 0.001);
        ok.("...and reports it back dirty",
            { var i = (2, 5 .. lastConfig.size - 1).detect { |k|
                lastConfig[k].asString == "tailSecs" };
              i.notNil and: { lastConfig[i + 2] == 1 } }.value);

        // save into a sandbox — never the project's own config.scd
        sandbox = (Platform.defaultTempDir ++ "ll-dash-test/").standardizePath;
        File.mkdir(sandbox);
        File(sandbox ++ "config.scd", "w")
            .write(File.readAllString("D:/livelooper/config.scd")).close;
        ~projectDir = sandbox;
        me.sendMsg('/cmd/saveConfig');
        0.6.wait;
        ok.("saveConfig replies with a count", lastSaved.notNil and: { lastSaved[1] > 0 });
        ok.("saving clears dirty",             ~settingsDirty.isEmpty);
        ok.("it wrote the sandbox, not the project",
            File.readAllString(sandbox ++ "config.scd").contains("~tailSecs  = 0.33"));

        "".postln;
        ("======== " ++ pass ++ " passed, " ++ fail ++ " failed ========").postln;
        0.5.wait;
        0.exit;
    };
});
)

