// ============================================================
//  LIVE LOOPER · dashboard-test.scd
//  The dashboard used to push 60 messages/second forever. It should now send a clock
//  reference ~2x/second and discrete state ONLY when something actually changes.
//
//  Run it headless (does NOT need the ZOOM H8 — boots the system default device):
//    & "C:\Program Files\SuperCollider-3.14.1\sclang.exe" -D d:/livelooper/test/dashboard-test.scd
//
//  Expect: "25 passed, 0 failed".
// ============================================================
(
var pass = 0, fail = 0, ok;
var clocks = 0, states = 0, legacy = 0, levels = 0;
var lastCps, lastPhase, lastDiv, lastState, lastLevels, lastInit, window = 4.0;

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
        // the retired chatty addresses must not come back
        OSCdef(\dtLegacyA, { |msg| legacy = legacy + 1 }, '/tick');
        OSCdef(\dtLegacyB, { |msg| legacy = legacy + 1 }, '/trackStates');

        ["looper.scd", "click.scd", "dashboard.scd"].do { |f|
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
        // /state = [addr, focus, clickOn, clickAmp, ...states]
        ok.("state carries every track",    lastState.size == (3 + ~tracks.size + 1));
        ok.("state reports the new value",  lastState[4].asSymbol == \recording);

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
        ok.("and its input label",
            lastInit[3].asString == ~inLabel.(~tracks[0]).asString);
        ok.("last pair carries the last track's name",
            lastInit[lastInit.size - 2].asString == ~tracks.last[\name].asString);

        "".postln;
        ("======== " ++ pass ++ " passed, " ++ fail ++ " failed ========").postln;
        0.5.wait;
        0.exit;
    };
});
)

