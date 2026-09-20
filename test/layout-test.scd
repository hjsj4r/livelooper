// ============================================================
//  LIVE LOOPER · layout-test.scd
//  Tracks are no longer fixed at boot: they can be added, removed, re-wired and renamed
//  while the rig runs, and the result written back to config.scd. This checks that the
//  session layout, the config variables and the dashboard stay in step through all of
//  it, and that a track can be re-wired WITHOUT losing its loop.
//
//  Run it headless (no ZOOM H8 needed):
//    & "C:\Program Files\SuperCollider-3.14.1\sclang.exe" -D d:/livelooper/test/layout-test.scd
//
//  Expect: "73 passed, 0 failed".
// ============================================================
(
var pass = 0, fail = 0, ok, t, a, b, sandbox, text, lines, nodeBefore, lastInit, inits = 0;
var settled;

ok = { |label, cond|
    if (cond) { pass = pass + 1; ("  PASS  " ++ label).postln }
             { fail = fail + 1; ("  FAIL  " ++ label).postln };
};
// wait until every track has a synth (adds and rebuilds are async), bounded
settled = { |secs = 3|
    var t0 = Main.elapsedTime;
    while { (~tracks.any { |x| x[\synth].isNil }) and: { (Main.elapsedTime - t0) < secs } } { 0.1.wait };
    0.2.wait;
};

s = Server(\llLayoutTest, NetAddr("127.0.0.1", 57157));
Server.default = s;
s.options.device = nil;
s.options.numInputBusChannels  = 12;
s.options.numOutputBusChannels = 2;
s.options.memSize = 8192 * 16;

s.waitForBoot({
    fork {
        1.0.wait;
        "D:/livelooper/config.scd".load;
        ~trackInputs = [9, [4, 7]];
        ~trackNames  = ["a", "pair"];
        ~maxTracks   = 5;
        ~dirtPort = NetAddr.langPort;
        ~dashPort = NetAddr.langPort;
        ~dirt = SuperDirt(2, s); ~dirt.start(~dirtPort, [0, 0]);
        1.0.wait;
        OSCdef(\ltInit, { |msg| inits = inits + 1; lastInit = msg }, '/tracksInit');
        "D:/livelooper/settings.scd".load;
        "D:/livelooper/looper.scd".load;
        // THE CLOCK IS DRIVEN BY HAND BELOW, so refuse live events: this SuperDirt
        // listens on sclang's own port, which is 57120 when it is free — the port a
        // running Tidal sends to. One stray event sets ~lastCycle to that session's
        // cycle counter (seen: 876) and every timing assertion here then measures the
        // wrong phrase. panic-test keeps receiveAction on purpose; it tests it.
        ~dirt.receiveAction = nil;
        "D:/livelooper/dashboard.scd".load;
        settled.(5);
        1.0.wait;

        "".postln; "--- BUILT FROM CONFIG ---".postln;
        ok.("two tracks from ~trackInputs",   ~tracks.size == 2);
        ok.("names from ~trackNames",         ~tracks[0][\name] == "a" and: { ~tracks[1][\name] == "pair" });
        ok.("stereo pair kept as a pair",     ~tracks[1][\inputs] == [4, 7]);
        ok.("nothing unsaved after a load",   (~settingsDirty ? []).isEmpty);
        ok.("dashboard was told the layout",  lastInit.notNil and: { lastInit[1] == 2 });

        "".postln; "--- ADD ---".postln;
        inits = 0;
        t = ~addTrack.(5, "new");
        settled.();
        ok.("addTrack returns the track",     t.notNil and: { t[\idx] == 2 });
        ok.("three tracks now",               ~tracks.size == 3);
        ok.("it has a synth",                 t[\synth].notNil);
        ok.("mono input -> 1-channel buffer", t[\buf].numChannels == 1);
        ok.("name taken",                     t[\name] == "new");
        ok.("~trackInputs follows",           ~trackInputs == [9, [4, 7], 5]);
        ok.("~trackNames follows",            ~trackNames == ["a", "pair", "new"]);
        ok.("layout marked unsaved",
            ~settingsDirty.any({ |k| k == \trackInputs }) and: { ~settingsDirty.any { |k| k == \trackNames } });
        ok.("dashboard re-sent the strips",   inits >= 1 and: { lastInit[1] == 3 });

        t = ~addTrack.([2, 3]);
        settled.();
        ok.("stereo add -> 2-channel buffer", t[\buf].numChannels == 2);
        ok.("unnamed track gets a default",   t[\name] == "Track 3");
        ok.("pair stored as a pair",          ~trackInputs.last == [2, 3]);

        "".postln; "--- LIMITS ---".postln;
        ok.("input past ~numInputs refused",  ~addTrack.(99).isNil and: { ~tracks.size == 4 });
        ok.("negative input refused",         ~addTrack.(-1).isNil);
        ok.("three inputs refused",           ~addTrack.([1, 2, 3]).isNil);
        ~addTrack.(1, "fifth"); settled.();
        ok.("fifth track allowed (cap 5)",    ~tracks.size == 5);
        ok.("sixth refused by ~maxTracks",    ~addTrack.(0).isNil and: { ~tracks.size == 5 });
        ~removeTrack.(4);
        ok.("back to four",                   ~tracks.size == 4);

        "".postln; "--- RENAME ---".postln;
        ~renameTrack.(0, "guitar");
        ok.("name changes",                   ~tracks[0][\name] == "guitar");
        ok.("~trackNames follows",            ~trackNames[0] == "guitar");
        ~renameTrack.(0, "   ");
        ok.("blank name falls back",          ~tracks[0][\name] == "Track 0");

        "".postln; "--- RE-WIRE, SAME WIDTH: THE LOOP SURVIVES ---".postln;
        t = ~tracks[0];
        t[\loopFrames] = ~loopFramesFor.(2.0);
        t[\buf].loadCollection(Array.fill(t[\loopFrames], { |i| 0.4 * sin(2pi * 300 * i / s.sampleRate) }), 0);
        t[\synth].set(\loopFrames, t[\loopFrames], \recRun, 0, \preLevel, 1, \playing, 1, \monLevel, 0);
        t[\state] = \playing;
        s.sync;
        nodeBefore = t[\synth].nodeID;
        ~setTrackInput.(0, 8);
        0.3.wait;
        ok.("inputs updated",                 t[\inputs] == [8]);
        ok.("same synth — no rebuild",        t[\synth].nodeID == nodeBefore);
        ok.("state untouched",                t[\state] == \playing);
        ok.("~trackInputs follows",           ~trackInputs[0] == 8);
        ~gotIn = nil;
        t[\synth].get(\inChan, { |v| ~gotIn = v });
        0.4.wait;
        ok.("the synth reads the new jack",   ~gotIn.notNil and: { ~gotIn.round == 8 });
        ok.("same input is a no-op",          ~setTrackInput.(0, 8) === t and: { t[\synth].nodeID == nodeBefore });
        ok.("bad input refused",              ~setTrackInput.(0, 99).isNil and: { t[\inputs] == [8] });

        "".postln; "--- RE-WIRE, WIDTH CHANGE: REBUILT ---".postln;
        ~setTrackInput.(0, [8, 9]);
        settled.();
        ok.("now a pair",                     t[\inputs] == [8, 9]);
        ok.("new synth",                      t[\synth].notNil and: { t[\synth].nodeID != nodeBefore });
        ok.("2-channel buffer",               t[\buf].numChannels == 2);
        ok.("loop is gone (documented)",      t[\state] == \idle);
        ok.("~trackInputs is a pair",         ~trackInputs[0] == [8, 9]);

        "".postln; "--- METERS ---".postln;
        // the synth only reports while subscribed; feed a loop so the OUT meter has
        // something to see
        t = ~tracks[1];
        t[\loopFrames] = ~loopFramesFor.(2.0);
        t[\buf].loadCollection(Array.fill(t[\loopFrames] * 2, { |i| 0.4 * sin(2pi * 300 * i / s.sampleRate) }), 0);
        t[\synth].set(\loopFrames, t[\loopFrames], \recRun, 0, \preLevel, 1, \playing, 1, \monLevel, 0);
        s.sync;
        ok.("meters start off",               (~metersOn ? false) == false);
        // the way the browser does it: a subscription the dashboard task keeps alive
        NetAddr.localAddr.sendMsg('/cmd/meters', 1);
        0.8.wait;
        ok.("subscribing turns them on",      ~metersOn == true);
        ok.("input level is reported",        t[\inAmp].isNumber);
        ("        (loop out reads " ++ (t[\outAmp] ? -1).round(0.001) ++ ")").postln;
        ok.("loop output is metered",         (t[\outAmp] ? 0) > 0.05);
        ok.("idle track reads silent",        (~tracks[2][\outAmp] ? 0) < 0.01);
        NetAddr.localAddr.sendMsg('/cmd/meters', 0);
        0.3.wait;
        ok.("unsubscribing clears them",      ~metersOn == false and: { t[\outAmp] == 0 });

        "".postln; "--- REMOVE ---".postln;
        // pins and focus must follow the tracks they were on
        ~pinned = [1, 3]; ~focus = 3;
        a = ~tracks[2]; b = ~tracks[3];
        inits = 0;
        ~removeTrack.(1);
        0.3.wait;
        ok.("three tracks left",              ~tracks.size == 3);
        ok.("indices renumbered",             ~tracks.collect({ |x| x[\idx] }) == [0, 1, 2]);
        ok.("the later tracks slid down",     ~tracks[1] === a and: { ~tracks[2] === b });
        ok.("pin on the removed track gone, the other followed", ~pinned == [2]);
        ok.("focus followed its track",       ~focus == 2);
        ok.("~trackInputs shrank",            ~trackInputs.size == 3 and: { ~trackNames.size == 3 });
        ok.("dashboard re-sent the strips",   inits >= 1 and: { lastInit[1] == 3 });
        ok.("no such track is refused",       ~removeTrack.(9).isNil);

        // removing a track mid-take must not leave a scheduled start to fire on a dead synth
        ~cps = 2.0; ~lastCycle = 0; ~lastEventTime = Main.elapsedTime;
        t = ~tracks[2];
        ~startRecording.(t);
        ~removeTrack.(2);
        1.5.wait;                          // past where the take would have started
        ok.("remove during a pending take is clean", ~tracks.size == 2 and: { t[\synth].isNil });

        // focus on the last track, remove it -> focus lands on what is now there
        ~focus = 1; ~pinned = [];
        ~removeTrack.(1);
        ok.("focus clipped into range",       ~focus == 1 and: { ~navIsTrack.(1).not });   // = tidal level
        ok.("one track left",                 ~tracks.size == 1);

        "".postln; "--- SAVE: THE LAYOUT GOES TO CONFIG.SCD ---".postln;
        ok.("pairs print bare",   ~settingsValueString.([[0, 1], 5, 9]) == "[[0, 1], 5, 9]");
        ok.("names print quoted", ~settingsValueString.(["mic", "bass"]) == "[\"mic\", \"bass\"]");
        ok.("nil prints as nil",  ~settingsValueString.(nil) == "nil");
        ok.("ints stay ints",     ~settingsValueString.(44100) == "44100");
        ok.("a device name is quoted", ~settingsValueString.("ASIO : ZOOM H8 Audio Driver") == "\"ASIO : ZOOM H8 Audio Driver\"");

        sandbox = (Platform.defaultTempDir ++ "ll-layout-test/").standardizePath;
        File.mkdir(sandbox);
        if (File.exists(sandbox ++ "config.scd")) { File.delete(sandbox ++ "config.scd") };
        File.copy("D:/livelooper/config.scd", sandbox ++ "config.scd");
        ~settingsPath = { sandbox ++ "config.scd" };
        ~addTrack.(6, "added at soundcheck"); settled.();
        ~audioDevice = nil; ~inDevice = "In Thing"; ~outDevice = "Out Thing"; ~sampleRate = 48000;
        ~settingsSave.();
        text  = File.readAllString(sandbox ++ "config.scd");
        lines = text.split($\n);
        ok.("~trackInputs line rewritten",
            lines.any { |l| l.beginsWith("~trackInputs") and: { l.contains("= [[8, 9], 6];") } });
        ok.("~trackNames line rewritten",
            lines.any { |l| l.beginsWith("~trackNames") and: { l.contains("\"added at soundcheck\"") } });
        ok.("~audioDevice written as nil",   lines.any { |l| l.beginsWith("~audioDevice = nil;") });
        ok.("~inDevice written",             lines.any { |l| l.beginsWith("~inDevice") and: { l.contains("\"In Thing\";") } });
        ok.("~sampleRate written",           lines.any { |l| l.beginsWith("~sampleRate") and: { l.contains("= 48000;") } });
        ok.("comments survive",              lines.any { |l| l.contains("Verified so far on this H8") });
        ok.("nothing unsaved afterwards",    ~settingsDirty.isEmpty);

        // round trip: the file the dashboard wrote is the layout the rig boots with
        ~trackInputs = nil; ~trackNames = nil;
        (sandbox ++ "config.scd").load;
        ok.("file loads back the inputs",    ~trackInputs == [[8, 9], 6]);
        ok.("file loads back the names",     ~trackNames == ["Track 0", "added at soundcheck"]);
        ok.("file loads back the devices",   ~inDevice == "In Thing" and: { ~audioDevice.isNil });

        "".postln; "--- RELOAD FROM FILE REBUILDS ---".postln;
        // change the file's layout behind the session's back, then reload
        text = text.replace("~trackInputs   = [[8, 9], 6];", "~trackInputs   = [3];")
                   .replace("~trackNames    = [\"Track 0\", \"added at soundcheck\"];",
                            "~trackNames    = [\"only\"];");
        File.use(sandbox ++ "config.scd", "w", { |f| f.write(text) });
        ~settingsReload.();
        settled.(5);
        ok.("tracks rebuilt from the file",  ~tracks.size == 1 and: { ~tracks[0][\name] == "only" });
        ok.("...on the file's input",        ~tracks[0][\inputs] == [3]);
        ok.("reload leaves nothing unsaved", ~settingsDirty.isEmpty);

        "".postln;
        ("======== " ++ pass ++ " passed, " ++ fail ++ " failed ========").postln;
        0.5.wait;
        0.exit;
    };
});
)
