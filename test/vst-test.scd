// ============================================================
//  LIVE LOOPER · vst-test.scd
//  VST instruments hosted inside the server: found by the scan, opened by name, played
//  from Tidal's event path and from a MIDI keyboard, metered, levelled, snapshotted, and
//  rebuilt after Ctrl+. — for real, with Surge XT.
//
//  Needs the VSTPlugin extension and Surge XT in D:/vst (see README). Without them the
//  test reports that and stops rather than failing everything.
//
//  Run it headless (no ZOOM H8 needed):
//    & "C:\Program Files\SuperCollider-3.14.1\sclang.exe" -D d:/livelooper/test/vst-test.scd
//
//  Expect: "39 passed, 0 failed".
// ============================================================
(
var pass = 0, fail = 0, ok, waitFor, inst, node, sandboxNote;

ok = { |label, cond|
    if (cond) { pass = pass + 1; ("  PASS  " ++ label).postln }
             { fail = fail + 1; ("  FAIL  " ++ label).postln };
};
waitFor = { |cond, secs = 10|
    var t = Main.elapsedTime;
    while { cond.value.not and: { (Main.elapsedTime - t) < secs } } { 0.1.wait };
    cond.value;
};

s = Server(\llVstTest, NetAddr("127.0.0.1", 57161));
Server.default = s;
s.options.device = nil;
s.options.numInputBusChannels  = 2;
s.options.numOutputBusChannels = 2;
s.options.memSize = 8192 * 16;

s.waitForBoot({
    fork {
        1.0.wait;
        "D:/livelooper/config.scd".load;
        ~trackInputs = []; ~trackNames = [];
        ~vstInstruments = [];
        ~vstDirs  = ["D:/vst"];
        ~dirtPort = NetAddr.langPort;
        ~dashPort = NetAddr.langPort;
        ~dirt = SuperDirt(2, s); ~dirt.start(~dirtPort, [0, 0]);
        SuperDirt.default = ~dirt;
        // one real bank, so "bd" is a name an instrument must not be allowed to shadow
        ~dirt.loadSoundFileFolder(SuperDirt.filenameSymbol.asString.dirname.dirname.dirname
            +/+ "Dirt-Samples/bd", \bd);
        1.0.wait;
        ["settings.scd", "looper.scd", "vst.scd", "dashboard.scd"].do { |f| ("D:/livelooper/" ++ f).load };
        0.5.wait;

        if (~vstAvailable.not) {
            "  SKIP  VSTPlugin extension not installed — nothing to test".postln;
            "======== 0 passed, 0 failed (skipped) ========".postln;
            0.5.wait; 0.exit;
        };

        "".postln; "--- THE SCAN ---".postln;
        waitFor.({ ~vstPlugins.notEmpty }, 30);
        ok.("scan finds plugins",             ~vstPlugins.notEmpty);
        ok.("Surge XT is among them",         ~vstPluginKnown.("Surge XT.vst3"));
        ok.("no instruments yet",             ~vsts.isEmpty and: { ~vstMidiTarget.isNil });

        "".postln; "--- ADD ---".postln;
        inst = ~vstAdd.("surge", "Surge XT.vst3");
        ok.("vstAdd returns the instrument",  inst.notNil and: { inst[\idx] == 0 });
        waitFor.({ inst[\state] == \open }, 20);
        ok.("plugin opens",                   inst[\state] == \open);
        ok.("controller is loaded",           inst[\ctl].notNil and: { inst[\ctl].loaded });
        ok.("has its own stereo bus",         inst[\bus].notNil and: { inst[\bus].numChannels == 2 });
        ok.("~vstInstruments follows",        ~vstInstruments == [["surge", "Surge XT.vst3"]]);
        ok.("layout marked unsaved",          ~settingsDirty.any { |k| k == \vstInstruments });
        ok.("first instrument takes the keyboard", ~vstMidiTarget == 0);
        ok.("Tidal knows # s \"surge\"",      ~dirt.soundLibrary.synthEvents[\surge].notNil);

        "".postln; "--- REFUSALS ---".postln;
        ok.("duplicate name refused",         ~vstAdd.("surge", "Surge XT.vst3").isNil);
        ok.("unknown plugin refused",         ~vstAdd.("x", "Nope.vst3").isNil);
        ok.("a sample bank's name refused",   ~vstAdd.("bd", "Surge XT.vst3").isNil);
        ok.("empty name refused",             ~vstAdd.("  ", "Surge XT.vst3").isNil);
        ok.("still one instrument",           ~vsts.size == 1);

        "".postln; "--- SOUND FROM TIDAL'S EVENT PATH ---".postln;
        NetAddr.localAddr.sendMsg('/cmd/meters', 1);
        0.6.wait;
        ok.("instrument meters on with the subscription", inst[\fader].notNil);
        ok.("silent before a note",           (inst[\outAmp] ? 0) < 0.005);
        // the \dirt event type is what a Tidal message becomes inside SuperDirt
        (type: \dirt, dirt: ~dirt, s: \surge, n: 0, sustain: 1.0, orbit: 0, cps: 0.5, delta: 1).play;
        0.6.wait;
        ("        (level with a note sounding: " ++ (inst[\outAmp] ? 0).round(0.001) ++ ")").postln;
        ok.("a note sounds",                  (inst[\outAmp] ? 0) > 0.01);
        waitFor.({ (inst[\outAmp] ? 0) < 0.005 }, 6);
        ok.("...and stops after its sustain", (inst[\outAmp] ? 0) < 0.005);

        "".postln; "--- SOUND FROM A MIDI KEYBOARD ---".postln;
        // MIDIIn's class-side hooks are exactly what a real port calls
        MIDIIn.doNoteOnAction(0, 0, 60, 100);
        0.5.wait;
        ok.("keyboard note sounds",           (inst[\outAmp] ? 0) > 0.01);
        MIDIIn.doNoteOffAction(0, 0, 60, 0);
        waitFor.({ (inst[\outAmp] ? 0) < 0.005 }, 6);
        ok.("...and stops on note off",       (inst[\outAmp] ? 0) < 0.005);
        ~setVstMidiTarget.(-1);
        ok.("target can be cleared",          ~vstMidiTarget.isNil);
        MIDIIn.doNoteOnAction(0, 0, 60, 100);
        0.5.wait;
        ok.("no target -> keyboard is silent", (inst[\outAmp] ? 0) < 0.005);
        MIDIIn.doNoteOffAction(0, 0, 60, 0);
        ~setVstMidiTarget.(0);

        "".postln; "--- LEVEL ---".postln;
        ~vstLevel.(inst, 0);
        MIDIIn.doNoteOnAction(0, 0, 64, 100);
        0.5.wait;
        ok.("level 0 mutes the instrument",   (inst[\outAmp] ? 0) < 0.005);
        ~vstLevel.(inst, 1);
        0.4.wait;
        ok.("level 1 brings it back",         (inst[\outAmp] ? 0) > 0.01);
        MIDIIn.doNoteOffAction(0, 0, 64, 0);
        ok.("level is clamped",               ~vstLevel.(inst, 3) == 1);

        "".postln; "--- SNAPSHOT + PANIC ---".postln;
        ~vstSnapshot.(inst);
        waitFor.({ inst[\data].notNil }, 10);
        ok.("program data captured",          inst[\data].notNil and: { inst[\data].size > 100 });
        node = inst[\synth].nodeID;
        CmdPeriod.run;                       // Ctrl+.
        waitFor.({ inst[\state] == \open and: { inst[\synth].nodeID != node } }, 20);
        ok.("rebuilt after Ctrl+.",           inst[\state] == \open and: { inst[\synth].nodeID != node });
        ok.("Tidal entry re-registered",      ~dirt.soundLibrary.synthEvents[\surge].notNil);
        NetAddr.localAddr.sendMsg('/cmd/meters', 1);
        0.5.wait;
        MIDIIn.doNoteOnAction(0, 0, 60, 100);
        0.5.wait;
        ok.("still sounds after the panic",   (inst[\outAmp] ? 0) > 0.01);
        MIDIIn.doNoteOffAction(0, 0, 60, 0);

        "".postln; "--- REMOVE ---".postln;
        ~vstRemove.(0);
        ok.("instrument gone",                ~vsts.isEmpty);
        ok.("~vstInstruments empty",          ~vstInstruments.isEmpty);
        ok.("Tidal entry gone",               ~dirt.soundLibrary.synthEvents[\surge].isNil);
        ok.("no MIDI target left",            ~vstMidiTarget.isNil);
        ok.("no such instrument refused",     ~vstRemove.(5).isNil);

        "".postln; "--- REBUILD FROM CONFIG ---".postln;
        ~vstInstruments = [["s1", "Surge XT.vst3"], ["bad", "Nope.vst3"]];
        ~rebuildVsts.();
        waitFor.({ ~vsts.size == 2 and: { ~vsts[0][\state] == \open } and: { ~vsts[1][\state] == \failed } }, 20);
        ok.("known plugin opens",             ~vsts[0][\state] == \open);
        ok.("unknown plugin is marked failed, not fatal", ~vsts[1][\state] == \failed);
        ok.("saved as name/plugin pairs",
            ~settingsValueString.(~vstInstruments) == "[[\"s1\", \"Surge XT.vst3\"], [\"bad\", \"Nope.vst3\"]]");

        "".postln;
        ("======== " ++ pass ++ " passed, " ++ fail ++ " failed ========").postln;
        0.5.wait;
        0.exit;
    };
});
)
