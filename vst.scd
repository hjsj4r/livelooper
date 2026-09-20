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
~vstMeterNodes = ~vstMeterNodes ? IdentityDictionary.new;
~midiSources  = ~midiSources ? [];  // [(uid:, device:, name:, label:), ...]
~midiGen      = ~midiGen ? 0;       // bumped when the source list changes

if (~vstAvailable.not) {
    "vst.scd: the VSTPlugin extension is not installed — instruments disabled. See README.".warn;
    ~vstAdd = { |...args| "vst: VSTPlugin is not installed".warn; nil };
    ~vstRemove = ~vstAdd; ~vstEditor = ~vstAdd; ~vstSearch = { |done| done.value([]) };
    ~vstLevel = { |inst, v| nil }; ~rebuildVsts = { nil }; ~setVstMeters = { |on| nil };
    ~scanMidiSources = { |done| ~midiSources = []; done.value(~midiSources) };
    ~vstSetMidiSource = { |i, label| nil };
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

// midiSrc is which keyboard plays this instrument, stored as the DEVICE LABEL rather
// than the uid: uids are assigned per session and change when you replug, so a saved
// "uid 0" would point at whatever happens to be first tomorrow. "" = none, "*" = any
// device, anything else = that label.
~newVst = { |name, plugin, i, midiSrc|
    (idx: i, name: name.asString, plugin: plugin.asString, bus: nil, synth: nil,
        fader: nil, ctl: nil, level: 1.0, state: \closed, data: nil, outAmp: 0,
        midiSrc: (midiSrc ? "").asString);
};

// synths + controller + open. Called at creation, after Ctrl+., after a reboot.
~buildVst = { |inst|
    ~ensureGroups !? { ~ensureGroups.() };
    // In ~srcGroup, which runs BEFORE the loopers — that is what lets a track record this
    // instrument in the same block instead of reading a bus scsynth has just cleared.
    // See the order-of-execution note in looper.scd.
    inst[\synth] = Synth(\vsti, [out: inst[\bus]], ~srcGroup);
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
            // A looper track bound to this instrument has been reading silence until
            // now (the bus did not exist), so point it at the real one.
            ~refreshVstTracks !? { ~refreshVstTracks.(inst[\name]) };
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
    // Hold the bus while clearing the field: any track recording this instrument has to
    // be moved off it BEFORE it is freed (~trackSourceBuses sends them to the silent bus
    // once the instrument is gone), and clearing the field first is what makes that
    // lookup fail over. Taking the reference first is also what stops the bus leaking.
    var bus = inst[\bus];
    inst[\bus] = nil;
    ~refreshVstTracks !? { ~refreshVstTracks.(inst[\name]) };
    inst[\fader] !? { |x| ~vstMeterNodes.removeAt(x.nodeID); x.free };
    inst[\ctl]   !? { |c| if (c.isOpen) { c.close } };
    inst[\synth] !? { |x| x.free };
    bus !? { |x| x.free };
    inst[\synth] = nil; inst[\fader] = nil; inst[\ctl] = nil;
    inst[\state] = \closed;
    inst;
};

// Keeps ~vstInstruments (what Save writes) in step with the session. Three fields per
// instrument; a two-field entry from an older config still loads (no MIDI source).
~syncVstVars = {
    ~vstInstruments = ~vsts.collect { |inst| [inst[\name], inst[\plugin], inst[\midiSrc] ? ""] };
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
    // The name is a Tidal sound name: `# s "surge"`. A space would read as two sounds in
    // mini-notation and punctuation has meanings there (`:` picks a sample, `~` rests),
    // so only letters, digits and underscore.
    { nm.isEmpty or: { nm.any { |c| c.isAlphaNum.not and: { c != $_ } } } } {
        ("vstAdd refused — " ++ nm.asCompileString
            ++ " is not a Tidal sound name: use letters, digits and _ (e.g. \"surge_synth\")").warn; nil }
    { ~vsts.any { |x| x[\name] == nm } or: { ~dirt.buffers[nm.asSymbol].notNil } } {
        ("vstAdd refused — the name " ++ nm.asCompileString
            ++ " is already an instrument or a sample bank").warn; nil }
    {
        inst = ~newVst.(nm, plugin, ~vsts.size,
            // The first instrument takes any keyboard, so one instrument plus one keyboard
            // needs no setting up. Once something IS bound, a new instrument starts on
            // none rather than silently doubling whatever you play.
            if (~vsts.any { |x| (x[\midiSrc] ? "").isEmpty.not }) { "" } { "*" });
        inst[\bus] = Bus.audio(s, 2);
        ~vsts = ~vsts ++ [inst];
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
        // MIDI bindings ride on the instruments themselves, so removing one cannot leave
        // a dangling target — there is simply one less thing listening.
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
    if (inst.isNil or: { inst[\ctl].isNil } or: { inst[\ctl].isOpen.not }) {
        ("vstEditor: instrument " ++ i ++ " is not open").warn; false;
    } {
        inst[\ctl].editor(show); true;
    };
};

// ── Hardware MIDI in ────────────────────────────────────────
// A keyboard is chosen PER INSTRUMENT, so two controllers can play two plugins at once,
// and adding a second instrument does not silently double what you play.
//
// The responders take everything and dispatch in the handler, rather than one set of
// MIDIdefs per source: re-binding is then a field on the instrument, not a teardown and
// rebuild of seven responders, and a device that arrives mid-set needs no new responder
// at all. .fix so Ctrl+. does not disconnect the keyboard.
//
// Straight through and untimestamped: for playing live you want the shortest path there
// is, and the jitter is one control block (~1.5 ms). Nothing here is compensated — you
// hear the instrument directly, so the only lever is keeping the path short.

// The label is what a person recognises and what gets saved. Windows usually reports
// device and name identically ("CASIO USB-MIDI"), so don't print it twice.
~midiLabel = { |device, name|
    var d = (device ? "").asString.stripWhiteSpace, n = (name ? "").asString.stripWhiteSpace;
    case { d.isEmpty } { n } { n.isEmpty or: { n == d } } { d } { d ++ " — " ++ n };
};

// A rescan that suddenly finds nothing where there was something is far more often a
// hiccup in re-initialising the MIDI client than a keyboard that actually vanished, and
// blanking the list would quietly drop the meaning of every binding — each one would
// resolve to no device and go silent. So keep what we knew and say so.
~midiMergeScan = { |found, known|
    if (found.isEmpty and: { (known ? []).notEmpty }) {
        ("vst: the MIDI rescan found nothing — keeping the " ++ known.size
            ++ " source(s) already known. Unplugged? Another program holding the port?").warn;
        known;
    } {
        found;
    };
};

// Re-enumerate. MIDIClient.init disposes the old client first, so this picks up a
// keyboard plugged in after boot; connectAll then opens every source. Both can throw on
// a machine with no MIDI at all, hence the try.
~scanMidiSources = { |done|
    var found;
    try {
        MIDIClient.init(verbose: false);
        MIDIIn.connectAll(false);
        found = MIDIClient.sources.collect { |e|
            (uid: e.uid, device: e.device.asString, name: e.name.asString,
                label: ~midiLabel.(e.device, e.name))
        };
        ~midiSources = ~midiMergeScan.(found, ~midiSources);
    } { |e|
        ("vst: MIDI scan failed — " ++ e.errorString
            ++ " (keeping " ++ ~midiSources.size ++ " known source(s))").warn;
    };
    ~midiGen = ~midiGen + 1;
    ~vstGen  = ~vstGen + 1;          // labels resolve against the new list
    ("vst: MIDI in — " ++ ~midiSources.size ++ " source(s)"
        ++ if (~midiSources.isEmpty) { "" } { ": " ++ ~midiSources.collect({ |x| x[\label] }).join(", ") }).postln;
    done.value(~midiSources);
    ~midiSources;
};

// Which uids a stored label means right now. A label that no longer matches anything
// (keyboard unplugged) resolves to nothing rather than to the wrong device.
~midiUidsFor = { |label|
    var l = (label ? "").asString;
    case
    { l.isEmpty } { [] }
    { l == "*" }  { ~midiSources.collect { |x| x[\uid] } }
    { ~midiSources.select({ |x| x[\label] == l }).collect { |x| x[\uid] } };
};

// Bind an instrument to a keyboard. "" = none, "*" = any device, else the label.
~vstSetMidiSource = { |i, label|
    var inst = ~vsts[i.asInteger], l = (label ? "").asString;
    case
    { inst.isNil } { ("vstSetMidiSource: no instrument " ++ i).warn; nil }
    { l.isEmpty.not and: { l != "*" } and: { ~midiSources.any({ |x| x[\label] == l }).not } } {
        ("vstSetMidiSource: no MIDI source called " ++ l.asCompileString
            ++ " — rescan, or pick one of: " ++ ~midiSources.collect({ |x| x[\label] }).join(", ")).warn;
        nil;
    }
    {
        inst[\midiSrc] = l;
        ~syncVstVars.();
        (~vstLabel.(inst) ++ " MIDI from "
            ++ case { l.isEmpty } { "nothing" } { l == "*" } { "any device" } { l }).postln;
        l;
    };
};

// What arrived last, and whether anything wanted it. This is the answer to "why is the
// keyboard silent": it separates "nothing is reaching SuperCollider" (cable, driver,
// another program holding the port) from "it arrives but no instrument is bound to that
// device", which look identical from the outside. The dashboard shows it live.
~midiLast = ~midiLast ? (text: "", label: "", time: 0, taken: 0);

if (~vstMidiIn ? true) {
    // src is the source's uid. An instrument on "*" takes everything; one bound to a
    // label takes only that device's uids.
    ~vstMidi = { |cmd, src ...args|
        var taken = 0;
        ~vsts.do { |inst|
            var l = inst[\midiSrc] ? "";
            if (l.isEmpty.not and: { (l == "*") or: { ~midiUidsFor.(l).any { |u| u == src } } }) {
                inst[\ctl] !? { |c| if (c.isOpen) { c.midi.performList(cmd, args); taken = taken + 1 } };
            };
        };
        // Only note-ons are worth showing — a clock or a stream of CCs would just blur.
        if (cmd == \noteOn) {
            ~midiLast = (
                text: "note " ++ args[1] ++ " vel " ++ args[2] ++ " ch " ++ (args[0] + 1),
                label: (~midiSources.detect({ |x| x[\uid] == src }) !? { |x| x[\label] })
                    ?? { "uid " ++ src },
                time: Main.elapsedTime, taken: taken);
            ~midiActivityGen = (~midiActivityGen ? 0) + 1;
        };
    };
    MIDIdef.noteOn (\vstNoteOn,  { |vel, num, chan, src| ~vstMidi.(\noteOn,  src, chan, num, vel) }).fix;
    MIDIdef.noteOff(\vstNoteOff, { |vel, num, chan, src| ~vstMidi.(\noteOff, src, chan, num, vel) }).fix;
    MIDIdef.cc     (\vstCc,      { |val, num, chan, src| ~vstMidi.(\control, src, chan, num, val) }).fix;
    MIDIdef.bend   (\vstBend,    { |val, chan, src|      ~vstMidi.(\bend,    src, chan, val) }).fix;
    MIDIdef.touch  (\vstTouch,   { |val, chan, src|      ~vstMidi.(\touch,   src, chan, val) }).fix;
    MIDIdef.polytouch(\vstPoly,  { |val, num, chan, src| ~vstMidi.(\polyTouch, src, chan, num, val) }).fix;
    MIDIdef.program(\vstProgram, { |val, chan, src|      ~vstMidi.(\program, src, chan, val) }).fix;
    // What is plugged in RIGHT NOW. Rescanned from the dashboard whenever you plug
    // something in mid-session.
    ~scanMidiSources.();
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
    inst[\ctl] !? { |c| if (c.isOpen) { c.getProgramData({ |d| inst[\data] = d }) } };
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

// From ~vstInstruments — what config.scd (or a later session file) says. Entries are
// [name, plugin, midiSrc]; a two-field entry from an older config still loads, with no
// keyboard bound.
~rebuildVsts = {
    ~vsts.do { |inst| ~freeVst.(inst) };
    ~vsts = ~vstInstruments.collect { |e, i| ~newVst.(e[0], e[1], i, e[2]) };
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
