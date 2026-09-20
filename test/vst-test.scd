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
//  Expect: "68 passed, 0 failed".
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
// Meters only flow while something keeps asking (~meterHold is 5 s), exactly as the
// browser does it. A block of assertions that takes longer than that must renew the
// subscription, or every level reads 0 and the tests lie.
~pulse = { NetAddr.localAddr.sendMsg('/cmd/meters', 1) };

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
        ok.("no instruments yet",             ~vsts.isEmpty);

        "".postln; "--- MIDI SOURCES ---".postln;
        ~scanMidiSources.();
        ("        (" ++ ~midiSources.size ++ " source(s): "
            ++ ~midiSources.collect({ |x| x[\label] }).join(", ") ++ ")").postln;
        ok.("scan returns a list",            ~midiSources.isKindOf(SequenceableCollection));
        ok.("every source has a uid + label", ~midiSources.every { |x| x[\uid].notNil and: { x[\label].isString } });
        ok.("labels are not doubled up",      ~midiLabel.("CASIO", "CASIO") == "CASIO");
        ok.("device and port both shown when they differ", ~midiLabel.("MPK", "port 1") == "MPK — port 1");
        ok.("\"\" resolves to no uids",       ~midiUidsFor.("").isEmpty);
        ok.("\"*\" resolves to every uid",    ~midiUidsFor.("*").size == ~midiSources.size);
        ok.("an unplugged label resolves to nothing", ~midiUidsFor.("no such keyboard").isEmpty);

        "".postln; "--- ADD ---".postln;
        inst = ~vstAdd.("surge", "Surge XT.vst3");
        ok.("vstAdd returns the instrument",  inst.notNil and: { inst[\idx] == 0 });
        waitFor.({ inst[\state] == \open }, 20);
        ok.("plugin opens",                   inst[\state] == \open);
        ok.("controller is loaded",           inst[\ctl].notNil and: { inst[\ctl].isOpen });
        ok.("has its own stereo bus",         inst[\bus].notNil and: { inst[\bus].numChannels == 2 });
        ok.("~vstInstruments follows",        ~vstInstruments == [["surge", "Surge XT.vst3", "*"]]);
        ok.("layout marked unsaved",          ~settingsDirty.any { |k| k == \vstInstruments });
        ok.("first instrument takes any keyboard", inst[\midiSrc] == "*");
        ok.("Tidal knows # s \"surge\"",      ~dirt.soundLibrary.synthEvents[\surge].notNil);

        "".postln; "--- REFUSALS ---".postln;
        ok.("duplicate name refused",         ~vstAdd.("surge", "Surge XT.vst3").isNil);
        ok.("unknown plugin refused",         ~vstAdd.("x", "Nope.vst3").isNil);
        ok.("a sample bank's name refused",   ~vstAdd.("bd", "Surge XT.vst3").isNil);
        ok.("empty name refused",             ~vstAdd.("  ", "Surge XT.vst3").isNil);
        ok.("a name with a space refused",    ~vstAdd.("surge synth", "Surge XT.vst3").isNil);
        ok.("punctuation refused",            ~vstAdd.("surge:1", "Surge XT.vst3").isNil);
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

        ~pulse.();
        "".postln; "--- SOUND FROM A MIDI KEYBOARD ---".postln;
        // MIDIIn's class-side hooks are exactly what a real port calls; the first
        // argument is the source uid, which is what the per-instrument binding matches.
        MIDIIn.doNoteOnAction(7777, 0, 60, 100);
        0.5.wait;
        ok.("\"any device\" plays whatever arrives", (inst[\outAmp] ? 0) > 0.01);
        MIDIIn.doNoteOffAction(7777, 0, 60, 0);
        waitFor.({ (inst[\outAmp] ? 0) < 0.005 }, 6);
        ok.("...and stops on note off",       (inst[\outAmp] ? 0) < 0.005);

        ~vstSetMidiSource.(0, "");
        ok.("binding can be cleared",         inst[\midiSrc] == "");
        MIDIIn.doNoteOnAction(7777, 0, 60, 100);
        0.5.wait;
        ok.("no binding -> silent",           (inst[\outAmp] ? 0) < 0.005);
        MIDIIn.doNoteOffAction(7777, 0, 60, 0);

        // Bound to ONE device: a fake source stands in for a second keyboard, so the
        // routing is tested whatever is actually plugged into this machine.
        ~midiSources = ~midiSources ++ [(uid: 4242, device: "Fake A", name: "Fake A", label: "Fake A")]
            ++ [(uid: 4343, device: "Fake B", name: "Fake B", label: "Fake B")];
        ~midiGen = ~midiGen + 1;
        ok.("bind to a named device",         ~vstSetMidiSource.(0, "Fake A") == "Fake A");
        ok.("...saved as the label",          ~vstInstruments[0][2] == "Fake A");
        ~pulse.();
        MIDIIn.doNoteOnAction(4242, 0, 60, 100);
        0.5.wait;
        ok.("that device plays it",           (inst[\outAmp] ? 0) > 0.01);
        MIDIIn.doNoteOffAction(4242, 0, 60, 0);
        waitFor.({ (inst[\outAmp] ? 0) < 0.005 }, 6);
        MIDIIn.doNoteOnAction(4343, 0, 60, 100);
        0.5.wait;
        ok.("another device does NOT",        (inst[\outAmp] ? 0) < 0.005);
        MIDIIn.doNoteOffAction(4343, 0, 60, 0);
        ok.("an unknown device is refused",   ~vstSetMidiSource.(0, "no such keyboard").isNil);
        ok.("...and the binding is unchanged", inst[\midiSrc] == "Fake A");

        // The activity readout is how "nothing is arriving" is told apart from "it
        // arrives but nothing is bound to that device" — they sound identical.
        MIDIIn.doNoteOnAction(4242, 0, 72, 99);
        0.2.wait;
        ok.("activity names the device",      ~midiLast[\label] == "Fake A");
        ok.("...and the note",                ~midiLast[\text].contains("note 72"));
        ok.("...and that something took it",  ~midiLast[\taken] == 1);
        MIDIIn.doNoteOffAction(4242, 0, 72, 0);
        MIDIIn.doNoteOnAction(4343, 0, 71, 99);
        0.2.wait;
        ok.("an unbound device reports 0 takers", ~midiLast[\taken] == 0
            and: { ~midiLast[\label] == "Fake B" });
        MIDIIn.doNoteOffAction(4343, 0, 71, 0);

        // A rescan that comes back empty must not wipe what we know — that would drop
        // every binding's meaning on a hiccup in the re-init.
        ok.("an empty rescan keeps the known sources",
            ~midiMergeScan.([], ~midiSources).size == ~midiSources.size);
        ok.("a rescan that finds something replaces the list",
            ~midiMergeScan.([(label: "New")], ~midiSources) == [(label: "New")]);
        ok.("empty on empty stays empty",     ~midiMergeScan.([], []).isEmpty);

        ~vstSetMidiSource.(0, "*");

        "".postln; "--- LEVEL ---".postln;
        ~pulse.(); 0.4.wait;
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
        ok.("nothing is bound to MIDI now",   ~vsts.every { |x| (x[\midiSrc] ? "").isEmpty });
        ok.("no such instrument refused",     ~vstRemove.(5).isNil);
        MIDIIn.doNoteOnAction(4242, 0, 60, 100);   // must not throw with no instruments
        MIDIIn.doNoteOffAction(4242, 0, 60, 0);
        ok.("MIDI with no instruments is harmless", true);

        "".postln; "--- TWO INSTRUMENTS, TWO KEYBOARDS ---".postln;
        ~vstAdd.("one", "Surge XT.vst3");
        ~vstAdd.("two", "Surge XT.vst3");
        waitFor.({ ~vsts.size == 2 and: { ~vsts.every { |x| x[\state] == \open } } }, 25);
        ok.("the first takes any device",     ~vsts[0][\midiSrc] == "*");
        ok.("the second starts unbound",      ~vsts[1][\midiSrc] == "");
        ~vstSetMidiSource.(0, "Fake A");
        ~vstSetMidiSource.(1, "Fake B");
        NetAddr.localAddr.sendMsg('/cmd/meters', 1);
        0.6.wait;
        MIDIIn.doNoteOnAction(4343, 0, 67, 100);
        0.6.wait;
        ok.("keyboard B plays instrument two", (~vsts[1][\outAmp] ? 0) > 0.01);
        ok.("...and not instrument one",       (~vsts[0][\outAmp] ? 0) < 0.005);
        MIDIIn.doNoteOffAction(4343, 0, 67, 0);
        waitFor.({ (~vsts[1][\outAmp] ? 0) < 0.005 }, 6);
        ~vstRemove.(1); ~vstRemove.(0);

        "".postln; "--- REBUILD FROM CONFIG ---".postln;
        ~vstInstruments = [["s1", "Surge XT.vst3", "Fake A"], ["bad", "Nope.vst3", ""]];
        ~rebuildVsts.();
        waitFor.({ ~vsts.size == 2 and: { ~vsts[0][\state] == \open } and: { ~vsts[1][\state] == \failed } }, 20);
        ok.("known plugin opens",             ~vsts[0][\state] == \open);
        ok.("unknown plugin is marked failed, not fatal", ~vsts[1][\state] == \failed);
        ok.("the saved keyboard is restored", ~vsts[0][\midiSrc] == "Fake A");
        ok.("saved as name/plugin/midi triples",
            ~settingsValueString.(~vstInstruments)
                == "[[\"s1\", \"Surge XT.vst3\", \"Fake A\"], [\"bad\", \"Nope.vst3\", \"\"]]");
        // a config written before this feature has two fields and must still load
        ~vstInstruments = [["old", "Surge XT.vst3"]];
        ~rebuildVsts.();
        waitFor.({ ~vsts.size == 1 and: { ~vsts[0][\state] == \open } }, 20);
        ok.("a two-field entry still loads",  ~vsts[0][\name] == "old" and: { ~vsts[0][\midiSrc] == "" });

        "".postln;
        ("======== " ++ pass ++ " passed, " ++ fail ++ " failed ========").postln;
        0.5.wait;
        0.exit;
    };
});
)
