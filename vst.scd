// ============================================================
//  LIVE LOOPER · vst.scd
//  VST instruments hosted INSIDE the server, played from Tidal and from a MIDI keyboard.
//  Loaded by startup.scd after looper.scd and click.scd.
//
//    ~vstAdd.("surge", "Surge XT.vst3");    // then in Tidal:  d1 $ n "0 4 7" # s "surge"
//    ~vstEditor.(0);                          // the plugin's own window
//    ~vstMidiTarget = 0;                      // hardware MIDI goes to instrument 0
//    ~vstRemove.(0);
//
//  HOW
//  The VSTPlugin extension (git.iem.at/pd/vstplugin) adds a UGen that runs a VST2/VST3
//  plugin in scsynth's audio thread, and a controller in sclang for MIDI, parameters,
//  presets and the editor window. Each instrument here is one \vsti synth writing to a
//  private stereo bus, plus a \vstFader that copies that bus to the main out with a level
//  and a meter — the same shape as a track, so a later step can point a looper at that
//  bus and record the instrument.
//
//  Tidal reaches an instrument through SuperDirt's own MIDI event type: addMIDI takes any
//  object with a MIDIOut-shaped API, and VSTPluginController.midi is exactly that. So
//  `# s "surge"` schedules noteOn/noteOff on SuperDirt's clock like it would for an
//  external synth, and every Tidal MIDI param (midichan, ccn/ccv, nrpn...) just works.
//
//  PANIC — Ctrl+. frees the synth and with it the plugin instance and everything you
//  dialled in. So each instrument's program data is snapshotted every ~vstSnapshotSecs
//  and put back when the ServerTree hook rebuilds it. A device switch (server reboot)
//  goes through the same path. That snapshot is also what a saved session will carry.
// ============================================================

~vstDirs ?? {
    Error("vst.scd: config.scd has not been loaded. Evaluate startup.scd instead.").throw
};
~dirt ?? {
    Error("vst.scd: SuperDirt is not running. Evaluate startup.scd instead.").throw
};

~vstAvailable = \VSTPlugin.asClass.notNil;
~vsts    = ~vsts ? [];
~vstGen  = ~vstGen ? 0;            // bumped when the list or an instrument's state changes
~vstPlugins = ~vstPlugins ? [];    // keys the scan found, sorted
~vstMidiTarget = ~vstMidiTarget ? nil;
~vstMeterNodes = ~vstMeterNodes ? IdentityDictionary.new;

if (~vstAvailable.not) {
    "vst.scd: the VSTPlugin extension is not installed — instruments disabled. See README.".warn;
    ~vstAdd = { |...args| "vst: VSTPlugin is not installed".warn; nil };
    ~vstRemove = ~vstAdd; ~vstEditor = ~vstAdd; ~vstSearch = { |done| done.value([]) };
    ~vstLevel = { |inst, v| nil }; ~rebuildVsts = { nil }; ~setVstMeters = { |on| nil };
} {

SynthDef(\vsti, { |out = 0|
    Out.ar(out, VSTPlugin.ar(nil, 2));
}).add;
SynthDef(\vstFader, { |inBus = 0, out = 0, level = 1|
    var sig = In.ar(inBus, 2) * Lag.kr(level, 0.05);
    SendReply.kr(Impulse.kr(\meterRate.kr(0)), '/vstMeter', Amplitude.kr(Mix(sig) / 2, 0.01, 0.15));
    Out.ar(out, sig);
}).add;

// ── The scan ────────────────────────────────────────────────
// VSTPlugin keeps a cache, so after the first run this is near-instant. Instruments can
// only be opened by key once it has completed, which is why every build goes through it.
~vstSearch = { |done|
    if (s.serverRunning.not) { done.value([]) } {
        VSTPlugin.search(s, dir: ~vstDirs, verbose: false, action: {
            ~vstPlugins = VSTPlugin.pluginList(s).collect({ |d| d.key.asString }).sort;
            ~vstGen = ~vstGen + 1;
            ("vst: " ++ ~vstPlugins.size ++ " plugins: " ++ ~vstPlugins.join(", ")).postln;
            done.value(~vstPlugins);
        });
    };
};
~vstPluginKnown = { |key| ~vstPlugins.any { |k| k == key.asString } };

// ── One instrument ──────────────────────────────────────────
~vstLabel = { |inst| "[vst" ++ inst[\idx] ++ " " ++ inst[\name] ++ "]" };

~newVst = { |name, plugin, i|
    (idx: i, name: name.asString, plugin: plugin.asString, bus: nil, synth: nil,
        fader: nil, ctl: nil, level: 1.0, state: \closed, data: nil, outAmp: 0);
};

// synths + controller + open. Called at creation, after Ctrl+., after a reboot.
~buildVst = { |inst|
    inst[\synth] = Synth(\vsti, [out: inst[\bus]]);
    inst[\fader] = Synth(\vstFader, [inBus: inst[\bus], out: 0, level: inst[\level],
        meterRate: if (~metersOn ? false) { ~meterRate ? 0 } { 0 }], addAction: \addToTail);
    ~vstMeterNodes[inst[\fader].nodeID] = inst;
    inst[\ctl]   = VSTPluginController(inst[\synth]);
    inst[\state] = \opening;
    ~vstGen = ~vstGen + 1;
    // editor: true prepares the plugin's window so ~vstEditor can show it later
    inst[\ctl].open(inst[\plugin], editor: true, action: { |c, ok|
        if (ok) {
            inst[\state] = \open;
            inst[\data] !? { |d| c.setProgramData(d) };          // back to how you left it
            // Tidal: `# s "<name>"` — same-named entry is replaced, so a rebuild is safe
            ~dirt.soundLibrary.addMIDI(inst[\name].asSymbol, c.midi);
            (~vstLabel.(inst) ++ " " ++ c.info.name ++ " by " ++ c.info.vendor
                ++ " — Tidal: # s \"" ++ inst[\name] ++ "\"").postln;
        } {
            inst[\state] = \failed;
            (~vstLabel.(inst) ++ " could not open " ++ inst[\plugin]).warn;
        };
        ~vstGen = ~vstGen + 1;
    });
    inst;
};

~freeVst = { |inst|
    inst[\fader] !? { |x| ~vstMeterNodes.removeAt(x.nodeID); x.free };
    inst[\ctl]   !? { |c| if (c.loaded) { c.close } };
    inst[\synth] !? { |x| x.free };
    inst[\bus]   !? { |x| x.free };
    inst[\synth] = nil; inst[\fader] = nil; inst[\ctl] = nil; inst[\bus] = nil;
    inst[\state] = \closed;
    inst;
};

// Keeps ~vstInstruments (what Save writes) in step with the session.
~syncVstVars = {
    ~vstInstruments = ~vsts.collect { |inst| [inst[\name], inst[\plugin]] };
    ~settingsMarkDirty !? { ~settingsMarkDirty.(\vstInstruments) };
    ~vstGen = ~vstGen + 1;
};

// ── Add / remove / level / editor ───────────────────────────
~vstAdd = { |name, plugin|
    var nm = name.asString.stripWhiteSpace, inst;
    case
    { ~vsts.size >= (~maxVsts ? 8) } { ("vstAdd refused — ~maxVsts is " ++ ~maxVsts).warn; nil }
    { ~vstPluginKnown.(plugin).not } {
        ("vstAdd refused — no plugin " ++ plugin.asString.asCompileString
            ++ " in the scan (" ++ ~vstPlugins.join(", ") ++ ")").warn; nil }
    { nm.isEmpty or: { ~vsts.any { |x| x[\name] == nm } } or: { ~dirt.buffers[nm.asSymbol].notNil } } {
        ("vstAdd refused — the name " ++ nm.asCompileString
            ++ " is empty, taken, or already a sample bank").warn; nil }
    {
        inst = ~newVst.(nm, plugin, ~vsts.size);
        inst[\bus] = Bus.audio(s, 2);
        ~vsts = ~vsts ++ [inst];
        ~vstMidiTarget ?? { ~vstMidiTarget = inst[\idx] };  // the first one gets the keyboard
        ~syncVstVars.();
        fork {
            s.sync;
            if (~vsts.any { |x| x === inst }) { ~buildVst.(inst) } { ~freeVst.(inst) };
        };
        inst;
    };
};

~vstRemove = { |i|
    var inst = ~vsts[i];
    if (inst.isNil) { ("vstRemove: no instrument " ++ i).warn; nil } {
        ~freeVst.(inst);
        ~dirt.soundLibrary.freeSynths(inst[\name].asSymbol);
        ~vsts = ~vsts.reject { |x| x === inst };
        ~vsts.do { |x, k| x[\idx] = k };
        ~vstMidiTarget = case
            { ~vsts.isEmpty } { nil }
            { ~vstMidiTarget.isNil } { nil }
            { ~vstMidiTarget == i } { 0 }
            { ~vstMidiTarget > i } { ~vstMidiTarget - 1 }
            { ~vstMidiTarget };
        ~syncVstVars.();
        (~vstLabel.(inst) ++ " REMOVED — " ++ ~vsts.size ++ " instruments").postln;
        inst;
    };
};

~vstLevel = { |inst, lvl|
    inst[\level] = lvl.clip(0, 1);
    inst[\fader] !? { |f| f.set(\level, inst[\level]) };
    inst[\level];
};

// The plugin's own GUI, in its own window. A native window, so it is not on the
// dashboard — the button there just asks for it.
~vstEditor = { |i, show = true|
    var inst = ~vsts[i.asInteger];
    if (inst.isNil or: { inst[\ctl].isNil } or: { inst[\ctl].loaded.not }) {
        ("vstEditor: instrument " ++ i ++ " is not open").warn; false;
    } {
        inst[\ctl].editor(show); true;
    };
};

~setVstMidiTarget = { |i|
    ~vstMidiTarget = if (i.isNil or: { i < 0 } or: { i >= ~vsts.size }) { nil } { i.asInteger };
    ~vstGen = ~vstGen + 1;
    ~vstMidiTarget;
};

// ── Hardware MIDI in ────────────────────────────────────────
// Everything a keyboard sends goes to ONE instrument, ~vstMidiTarget, channel untouched.
// Straight through, untimestamped: for playing live you want the shortest path, and the
// jitter is one control block. .fix so Ctrl+. does not disconnect the keyboard.
if (~vstMidiIn ? true) {
    if (MIDIClient.initialized.not) {
        try { MIDIClient.init(verbose: false); MIDIIn.connectAll(false) }
            { |e| ("vst: MIDI init failed — " ++ e.errorString).warn };
    };
    ~vstMidi = { |cmd ...args|
        ~vstMidiTarget !? { |i|
            ~vsts[i] !? { |inst| inst[\ctl] !? { |c| if (c.loaded) { c.midi.performList(cmd, args) } } };
        };
    };
    MIDIdef.noteOn (\vstNoteOn,  { |vel, num, chan| ~vstMidi.(\noteOn,  chan, num, vel) }).fix;
    MIDIdef.noteOff(\vstNoteOff, { |vel, num, chan| ~vstMidi.(\noteOff, chan, num, vel) }).fix;
    MIDIdef.cc     (\vstCc,      { |val, num, chan| ~vstMidi.(\control, chan, num, val) }).fix;
    MIDIdef.bend   (\vstBend,    { |val, chan|      ~vstMidi.(\bend,    chan, val) }).fix;
    MIDIdef.touch  (\vstTouch,   { |val, chan|      ~vstMidi.(\touch,   chan, val) }).fix;
    MIDIdef.polytouch(\vstPoly,  { |val, num, chan| ~vstMidi.(\polyTouch, chan, num, val) }).fix;
    MIDIdef.program(\vstProgram, { |val, chan|      ~vstMidi.(\program, chan, val) }).fix;
    ("vst: MIDI in — " ++ MIDIClient.sources.size ++ " source(s): "
        ++ MIDIClient.sources.collect({ |x| x.device ++ " " ++ x.name }).join(", ")).postln;
};

// ── Meters ──────────────────────────────────────────────────
OSCdef(\vstMeter, { |msg|
    ~vstMeterNodes[msg[1]] !? { |inst| inst[\outAmp] = msg[3] };
}, '/vstMeter').fix;
~setVstMeters = { |on|
    var rate = if (on) { ~meterRate ? 0 } { 0 };
    ~vsts.do { |inst| inst[\fader] !? { |f| f.set(\meterRate, rate) }; if (on.not) { inst[\outAmp] = 0 } };
};

// ── Snapshots: what survives a panic ────────────────────────
~vstSnapshot = { |inst|
    inst[\ctl] !? { |c| if (c.loaded) { c.getProgramData({ |d| inst[\data] = d }) } };
};
~vstSnapshotAll = { ~vsts.do { |inst| ~vstSnapshot.(inst) } };
~startVstSnapshots !? { CmdPeriod.remove(~startVstSnapshots) };
~startVstSnapshots = {
    ~vstSnapGen = (~vstSnapGen ? 0) + 1;
    ~vstSnapTask !? { |t| t.stop };
    if ((~vstSnapshotSecs ? 0) > 0) {
        ~vstSnapTask = Task({
            var myGen = ~vstSnapGen;
            while { myGen == ~vstSnapGen } { ~vstSnapshotSecs.wait; ~vstSnapshotAll.() };
        }).play(SystemClock);
    };
};
CmdPeriod.add(~startVstSnapshots);
~startVstSnapshots.();

// ── Rebuild after Ctrl+. / boot, forget on quit, build on load ──
~buildVsts !? { ServerTree.remove(~buildVsts, s) };
~buildVsts = {
    ~vstMeterNodes.clear;
    if (~vsts.any { |inst| inst[\bus].notNil }) {
        ~vstSearch.({ ~vsts.do { |inst| inst[\bus] !? { ~buildVst.(inst) } } });
    };
};
ServerTree.add(~buildVsts, s);

~forgetVsts !? { ServerQuit.remove(~forgetVsts, s) };
~forgetVsts = {
    ~vstMeterNodes.clear;
    ~vsts.do { |inst|
        inst[\bus] = nil; inst[\synth] = nil; inst[\fader] = nil; inst[\ctl] = nil;
        inst[\state] = \closed;
    };
};
ServerQuit.add(~forgetVsts, s);

// From ~vstInstruments — what config.scd (or a later session file) says.
~rebuildVsts = {
    ~vsts.do { |inst| ~freeVst.(inst) };
    ~vsts = ~vstInstruments.collect { |pair, i| ~newVst.(pair[0], pair[1], i) };
    ~vstMidiTarget = if (~vsts.isEmpty) { nil } { (~vstMidiTarget ? 0).clip(0, ~vsts.size - 1) };
    ~vstGen = ~vstGen + 1;
    fork {
        s.sync;
        ~vstSearch.({
            ~vsts.do { |inst|
                if (~vstPluginKnown.(inst[\plugin])) {
                    inst[\bus] = Bus.audio(s, 2);
                    ~buildVst.(inst);
                } {
                    inst[\state] = \failed;
                    (~vstLabel.(inst) ++ " plugin not found: " ++ inst[\plugin]).warn;
                };
            };
            ~vstGen = ~vstGen + 1;
        });
    };
};
~rebuildVsts.();

};   // ~vstAvailable

("=== vst.scd loaded — " ++ if (~vstAvailable) { ~vstInstruments.size.asString ++ " instruments" } { "VSTPlugin missing" } ++ " ===").postln;
