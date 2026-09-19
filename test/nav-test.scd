// ============================================================
//  LIVE LOOPER · nav-test.scd
//  Selection and level control — the DualSense stick and d-pad, and the dashboard's
//  /cmd/focus. This replaces midi-test.scd: the MPK mini map was removed, so the only
//  control surfaces left are the controller and the mouse.
//
//  The list runs tracks first, then the two mixer levels, in the order they appear
//  DOWN the dashboard. If you reorder the panels in index.html, reorder this too —
//  a stick that moves down the list while the highlight moves up the screen is the
//  bug this file exists to catch.
//
//  Run it headless (no controller needed — navigation is called directly):
//    & "C:\Program Files\SuperCollider-3.14.1\sclang.exe" -D d:/livelooper/test/nav-test.scd
//
//  Expect: "29 passed, 0 failed".
// ============================================================
(
var pass = 0, fail = 0, ok, other;

ok = { |label, cond|
    if (cond) { pass = pass + 1; ("  PASS  " ++ label).postln }
             { fail = fail + 1; ("  FAIL  " ++ label).postln };
};

// 57140, deliberately clear of the 5712x range: when another SuperCollider already holds
// the default lang port 57120, this sclang falls back to 57121/57122/... and a server
// addressed there would be talking to the interpreter itself.
s = Server(\llNavTest, NetAddr("127.0.0.1", 57140));
Server.default = s;
s.options.device = nil;
s.options.numInputBusChannels  = 12;
s.options.numOutputBusChannels = 2;
s.options.memSize = 8192 * 16;      // or SuperDirt fails to start and prints an error

s.waitForBoot({
    fork {
        1.0.wait;
        "D:/livelooper/config.scd".load;
        // a session starts with no tracks, so the test brings its own layout
        ~trackInputs = [9, 8, 5, [4, 7], 6, 3];   // six: the transport section indexes ~tracks[5]
        ~trackNames  = ["a", "b", "c", "pair", "e", "f"];
        ~dirtPort = NetAddr.langPort;
        ~dirt = SuperDirt(2, s);
        ~dirt.start(~dirtPort, [0, 0]);
        1.0.wait;
        ["looper.scd", "click.scd"].do { |f| ("D:/livelooper/" ++ f).load };
        while { ~tracks.isNil or: { ~tracks.any { |x| x[\synth].isNil } } } { 0.2.wait };
        ~cps = 4.0; ~lastCycle = 0; ~lastEventTime = Main.elapsedTime;   // 4 cycles = 1 s

        "".postln; "--- NO CONTROL SURFACE BUT THE CONTROLLER ---".postln;
        // The MPK responders were .fix'ed, so they outlive both Ctrl+. and a reload.
        // Loading looper.scd must free them by key or the old map keeps firing.
        [\looperPads, \looperKnobs, \looperPedal, \clickPedal, \midiPrint, \midiCcPrint]
            .do { |k| ok.("no MIDIdef " ++ k, MIDIdef.all[k].isNil) };
        // and nothing may still be reading the retired config keys
        ok.("config has no ~padRecord",  ~padRecord.isNil);
        ok.("config has no ~knobFader",  ~knobFader.isNil);

        "".postln; "--- NAVIGATION ---".postln;
        // stepping onto a track selects it outright — no separate commit
        ~focus = 0;
        ~navMove.(1);
        ok.("nav selects as it steps",   ~focus == 1);
        ~navMove.(1); ~navMove.(1);
        ok.("nav keeps stepping",        ~focus == 3);
        // The list runs past the tracks onto the two mixer levels, so the stick can
        // reach every fader without a mode.
        ok.("list is tracks + 2 mixer items", ~navSize.() == (~tracks.size + 2));
        ~focus = ~tracks.size - 1;
        ~navMove.(1);
        ok.("steps off the tracks onto tidal", ~focus == ~tracks.size);
        ok.("...which is not a track",         ~navIsTrack.().not);
        ok.("and is named",                    ~navName.() == "tidal level");
        ~navMove.(1);
        ok.("then onto click",                 ~focus == (~tracks.size + 1));
        ok.("which is the LAST item",          ~focus == (~navSize.() - 1));
        // wrapping, so running off the end doesn't feel broken with no scrollbar
        ~navMove.(1);
        ok.("wraps forward to the first track", ~focus == 0);
        ~navMove.(-1);
        ok.("wraps backward onto click",        ~focus == (~navSize.() - 1));
        ~navFocus.(2);
        ok.("navFocus jumps directly",   ~focus == 2);
        ok.("...and that IS a track",    ~navIsTrack.());

        "".postln; "--- STICK ADJUSTS THE SELECTED LEVEL ---".postln;
        ~navFocus.(1);
        ~trackLevel.(~tracks[1], 0.5);
        ~trackLevel.(~tracks[0], 0.8);
        other = ~tracks[0][\level];
        ~navAdjust.(0.2);
        ok.("adjusts the selected track", (~tracks[1][\level] - 0.7).abs < 0.001);
        ok.("leaves other tracks alone",  ~tracks[0][\level] == other);
        ~navAdjust.(9);
        ok.("clamps at 1",               ~tracks[1][\level] == 1.0);
        ~navAdjust.(-9);
        ok.("clamps at 0",               ~tracks[1][\level] == 0.0);
        ~trackLevel.(~tracks[1], 1.0);
        // and the mixer items respond to the same control
        ~navFocus.(~tracks.size);
        ~dirtLevel = 0.5; ~navAdjust.(0.25);
        ok.("adjusts the tidal level",   (~dirtLevel - 0.75).abs < 0.001);
        ~navFocus.(~tracks.size + 1);
        ~clickAmp = 0.5; ~navAdjust.(-0.25);
        ok.("adjusts the click level",   (~clickAmp - 0.25).abs < 0.001);
        ~clickAmp = 0.5; ~dirtLevel = 1.0;

        "".postln; "--- TRANSPORT FOLLOWS THE SELECTION ---".postln;
        // a transport action on a mixer item must do NOTHING
        ~navFocus.(~tracks.size);
        if (~navIsTrack.()) { ~trackRecord.(~tracks[~focus]) };
        0.3.wait;
        ok.("record on a mixer item is ignored",
            ~tracks.every { |x| x[\state] == \idle });
        ~navFocus.(2);
        ~trackRecord.(~tracks[~focus]);
        0.3.wait;
        ok.("record hits the selected track",
            ~tracks[2][\state] == \recording and: { ~tracks[5][\state] == \idle });
        ~trackClear.(~tracks[2]);
        0.3.wait;
        ok.("clear releases it",         ~tracks[2][\state] == \idle);

        "".postln;
        ("======== " ++ pass ++ " passed, " ++ fail ++ " failed ========").postln;
        0.5.wait;
        0.exit;
    };
});
)
