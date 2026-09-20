// ============================================================
//  LIVE LOOPER · dashboard.scd
//  Streams live state to the web dashboard and receives its commands.
//  Loaded by startup.scd BEFORE the server boots — nothing here needs the server, and
//  that is what lets the dashboard show a rig whose interface is missing and move it to
//  another one. Everything that reads ~tracks tolerates it not existing yet.
//
//  Start the bridge:  node d:/livelooper/dashboard/server.js
//  Then open:         http://localhost:3000
// ============================================================

~dashPort ?? {
    Error("dashboard.scd: config.scd has not been loaded. Evaluate startup.scd instead.").throw
};
~dash = NetAddr("127.0.0.1", ~dashPort);   // the Node bridge listens here for state

// ── Commands FROM the dashboard ─────────────────────────────
// The bridge forwards browser commands as OSC to sclang on :57120.
// Every one is .fix'ed — responders are freed by Ctrl+. otherwise, which would leave the
// dashboard visibly connected but completely inert.
~trk = { |i| (~tracks ? [])[i.asInteger] };
OSCdef(\cmdTrackRecord,  { |msg| ~trk.(msg[1]) !? { |t| ~trackRecord.(t) } },  '/cmd/trackRecord').fix;
OSCdef(\cmdTrackOverdub, { |msg| ~trk.(msg[1]) !? { |t| ~trackOverdub.(t) } }, '/cmd/trackOverdub').fix;
OSCdef(\cmdTrackClear, { |msg| ~trk.(msg[1]) !? { |t| ~trackClear.(t) } }, '/cmd/trackClear').fix;
OSCdef(\cmdTrackLevel, { |msg| ~trk.(msg[1]) !? { |t| ~trackLevel.(t, msg[2].asFloat) } }, '/cmd/trackLevel').fix;
// R2 pressure. Arrives often while the trigger moves, so the handler stays trivial.
OSCdef(\cmdTrackFx,    { |msg| ~trk.(msg[1]) !? { |t| ~trackFx.(t, msg[2].asFloat) } }, '/cmd/trackFx').fix;
OSCdef(\cmdFocus,      { |msg| ~navFocus !? { ~navFocus.(msg[1].asInteger) } }, '/cmd/focus').fix;

// The per-strip buttons above act on ONE track — the one whose button you clicked.
// The controller acts on the SELECTION (pinned tracks plus the focused one), which is
// why these are separate addresses rather than a flag on the same ones: a mouse click on
// a strip should never quietly fire on four tracks because something was pinned.
OSCdef(\cmdSelRecord,  { ~selDo !? { ~selDo.("record",  { |t| ~trackRecord.(t) }) } }, '/cmd/selRecord').fix;
OSCdef(\cmdSelOverdub, { ~selDo !? { ~selDo.("overdub", { |t| ~trackOverdub.(t) }) } }, '/cmd/selOverdub').fix;
OSCdef(\cmdSelClear,   { ~selDo !? { ~selDo.("clear",   { |t| ~trackClear.(t) }) } }, '/cmd/selClear').fix;
OSCdef(\cmdSelLoop,    { ~selDo !? { ~selDo.("stop/start", { |t| ~trackLoopToggle.(t) }) } },
    '/cmd/selLoopToggle').fix;
OSCdef(\cmdPinToggle,  { |msg| ~pinToggle !? { ~pinToggle.(if (msg.size > 1) { msg[1].asInteger }) } },
    '/cmd/pinToggle').fix;
OSCdef(\cmdPinClear,   { ~pinClear !? { ~pinClear.() } }, '/cmd/pinClear').fix;
// From the DualSense, relayed by the browser's Gamepad API through the bridge.
OSCdef(\cmdNavMove,    { |msg| ~navMove !? { ~navMove.(msg[1].asInteger) } }, '/cmd/navMove').fix;
// Left/right on the stick — nudges whatever the selection is sitting on, tracks and the
// two mixer items alike.
OSCdef(\cmdNavAdjust,  { |msg| ~navAdjust !? { ~navAdjust.(msg[1].asFloat) } }, '/cmd/navAdjust').fix;
OSCdef(\cmdTrackCycles, { |msg|
    ~trk.(msg[1]) !? { |t|
        if (msg.size > 2) { ~trackCycles.(t, msg[2].asInteger) } { ~trackCyclesNext.(t) };
    };
}, '/cmd/trackCycles').fix;
// Click level. Read live by the click Task on every beat, so it takes effect instantly.
OSCdef(\cmdClickAmp,   { |msg| ~clickAmp = msg[1].asFloat.clip(0, 1) }, '/cmd/clickAmp').fix;
OSCdef(\cmdClickToggle, {
    ~clickOn = (~clickOn ? false).not;
    ("Click " ++ (~clickOn.if({ "ON" }, { "OFF" }))).postln;
}, '/cmd/clickToggle').fix;
OSCdef(\cmdDirtLevel, { |msg|
    ~dirtLevel = msg[1].asFloat;
    ~dirtFader !? { ~dirtFader.set(\level, ~dirtLevel) };
}, '/cmd/dirtLevel').fix;

// ── Layout: add / remove / re-wire / rename ─────────────────
// Inputs arrive as one or two integers; a name as a string. Each action bumps
// ~layoutGen in looper.scd, which is what makes the task below resend /tracksInit.
OSCdef(\cmdAddTrack, { |msg|
    var ins = msg[1..].select(_.isNumber).collect(_.asInteger);
    var name = msg[1..].detect { |x| x.isString or: { x.isKindOf(Symbol) } };
    ~addTrack !? { ~addTrack.(ins, name !? { name.asString }) };
}, '/cmd/addTrack').fix;
OSCdef(\cmdRemoveTrack, { |msg| ~removeTrack !? { ~removeTrack.(msg[1].asInteger) } },
    '/cmd/removeTrack').fix;
OSCdef(\cmdSetTrackInput, { |msg|
    ~setTrackInput !? { ~setTrackInput.(msg[1].asInteger, msg[2..].collect(_.asInteger)) };
}, '/cmd/setTrackInput').fix;
OSCdef(\cmdRenameTrack, { |msg|
    ~renameTrack !? { ~renameTrack.(msg[1].asInteger, msg[2].asString) };
}, '/cmd/renameTrack').fix;

// ── VST instruments ─────────────────────────────────────────
OSCdef(\cmdVstAdd,    { |msg| ~vstAdd !? { ~vstAdd.(msg[1].asString, msg[2].asString) } }, '/cmd/vstAdd').fix;
OSCdef(\cmdVstRemove, { |msg| ~vstRemove !? { ~vstRemove.(msg[1].asInteger) } }, '/cmd/vstRemove').fix;
OSCdef(\cmdVstLevel,  { |msg| (~vsts ? [])[msg[1].asInteger] !? { |i| ~vstLevel.(i, msg[2].asFloat) } }, '/cmd/vstLevel').fix;
OSCdef(\cmdVstEditor, { |msg| ~vstEditor !? { ~vstEditor.(msg[1].asInteger) } }, '/cmd/vstEditor').fix;
// The MIDI source is per instrument, as a label ("" none, "*" any, else the device).
// A message with no label came from a dashboard page older than this feature, whose MIDI
// button sent only an index. Taking that as "unbind" would silence the instrument and
// look like broken MIDI, so say what it is instead.
OSCdef(\cmdVstMidi,   { |msg|
    if (msg.size > 2) {
        ~vstSetMidiSource !? { ~vstSetMidiSource.(msg[1].asInteger, msg[2].asString) };
    } {
        "dashboard: an old page sent /cmd/vstMidi without a device — reload it (Ctrl+Shift+R)".warn;
    };
}, '/cmd/vstMidi').fix;
OSCdef(\cmdVstScan,   { ~vstSearch !? { ~vstSearch.() } }, '/cmd/vstScan').fix;
OSCdef(\cmdMidiScan,  { ~scanMidiSources !? { ~scanMidiSources.() } }, '/cmd/midiScan').fix;

// The instruments: name, plugin, state and MIDI source label, four fields each.
~sendVsts = {
    var vsts = ~vsts ? [];
    ~dash.sendMsg('/vstInit', vsts.size, (~vstAvailable ? false).binaryValue,
        *vsts.collect({ |i| [i[\name].asString, i[\plugin].asString, i[\state].asString,
            (i[\midiSrc] ? "").asString] }).flatten);
};
~sendVstPlugins = {
    ~dash.sendMsg('/vstPlugins', *(~vstPlugins ? []).collect(_.asString));
};
// The keyboards this machine can see, by label — what the per-instrument menu offers.
~sendMidiSources = {
    ~dash.sendMsg('/midiSources', *(~midiSources ? []).collect({ |x| x[\label].asString }));
};
// The last note that arrived, which device it came from, and how many instruments took
// it. Sent only when a note actually arrives, so it costs nothing while you are not
// playing — and it is what tells you whether the keyboard is reaching SC at all.
~sendMidiActivity = {
    var m = ~midiLast ? ();
    ~dash.sendMsg('/midiActivity', (m[\label] ? "").asString, (m[\text] ? "").asString,
        (m[\taken] ? 0).asInteger);
};
~sendVstLevels = {
    ~dash.sendMsg('/vstLevels', *(~vsts ? []).collect({ |i| (i[\level] ? 1.0).asFloat }));
};

// ── Devices ─────────────────────────────────────────────────
// scan: async, the list goes out as /devices when it lands.
// useDevice: in, out, sampleRate (0 = device default), then optional in/out counts.
// An empty string is "system default", since OSC has no nil.
OSCdef(\cmdScanDevices, { ~scanDevices !? { ~scanDevices.() } }, '/cmd/scanDevices').fix;
OSCdef(\cmdUseDevice, { |msg|
    var str = { |x| if (x.isNil or: { x.asString.isEmpty }) { nil } { x.asString } };
    ~useDevice !? {
        ~useDevice.(str.(msg[1]), str.(msg[2]),
            if (msg.size > 3) { msg[3].asInteger } { nil },
            if (msg.size > 4) { msg[4].asInteger } { nil },
            if (msg.size > 5) { msg[5].asInteger } { nil },
            if (msg.size > 6) { msg[6].asInteger } { nil });
        ~sendConfig.();
    };
}, '/cmd/useDevice').fix;
OSCdef(\cmdRebootRig, { ~rebootRig !? { ~rebootRig.() } }, '/cmd/rebootRig').fix;

// ── Meters ──────────────────────────────────────────────────
// The browser re-subscribes every couple of seconds while it is open and visible. No
// heartbeat for ~meterHold seconds and the synths go quiet again, so a closed tab never
// leaves the rig streaming levels to nobody.
~meterHold  = 5.0;
~meterUntil = 0;
OSCdef(\cmdMeters, { |msg|
    var on = if (msg.size > 1) { msg[1].asInteger > 0 } { true };
    ~meterUntil = if (on) { Main.elapsedTime + ~meterHold } { 0 };
    ~setMeters !? { if (on != (~metersOn ? false)) { ~setMeters.(on) } };
}, '/cmd/meters').fix;

// Track config → the dashboard builds its strips from this. Sent as name/input PAIRS so
// the two can't drift out of alignment, and as strings because a stereo track is fed by
// two inputs and reads as "0+1".
~sendTracks = {
    var tracks = ~tracks ? [];
    ~dash.sendMsg('/tracksInit', tracks.size,
        *tracks.collect({ |t| [t[\name].asString, ~inLabel.(t).asString] }).flatten);
};

// The rig itself: boot state, the devices it is configured for, and the limits the
// Setup view needs to build its controls (how many inputs there are to choose from, how
// many tracks may be added). The config's device is sent beside the RUNNING one, so the
// page can show "config says H8, running on default" after a reload from file.
~sendRig = {
    var pair = ~configuredDevices !? { ~configuredDevices.() } ?? { [~audioDevice, ~audioDevice] };
    ~dash.sendMsg('/rig',
        (~bootState ? \off).asString, (~bootMsg ? "").asString,
        (pair[0] ? "").asString, (pair[1] ? "").asString,
        (~sampleRate ? 0).asInteger, (~numInputs ? 0).asInteger, (~numOutputs ? 0).asInteger,
        (~maxTracks ? 12).asInteger,
        (s.options.inDevice ? "").asString, (s.options.outDevice ? "").asString,
        (if (s.serverRunning) { s.sampleRate ? 0 } { 0 }).asInteger,
        (~scanning ? false).binaryValue, (~maxVsts ? 8).asInteger,
        (~hardwareBufferSize ? 0).asInteger, (s.options.hardwareBufferSize ? 0).asInteger);
};

// The scan result: name, ins, outs per device. Chunked, because Windows lists 20-odd
// endpoints with long names and one UDP packet has a ceiling.
~sendDevices = {
    var devs = ~devices ? [];
    ~dash.sendMsg('/devicesClear');
    devs.clump(8).do { |chunk|
        ~dash.sendMsg('/devicesAdd', *chunk.collect({ |d|
            [d[\name].asString, d[\ins].asInteger, d[\outs].asInteger]
        }).flatten);
    };
    ~dash.sendMsg('/devicesDone', devs.size);
};

// ── Settings ────────────────────────────────────────────────
// Guarded on ~settingsSpec: the test suites load looper/click/dashboard without
// settings.scd, and a missing settings module should leave the rest of the dashboard
// working rather than throwing on every message.
~sendConfigSpec = {
    ~settingsSpec !? {
        ~dash.sendMsg('/configSpec', *~settingsSpec.collect({ |e|
            [e[\key].asString, e[\label], e[\min].asFloat, e[\max].asFloat,
                e[\step].asFloat, e[\when], e[\note]]
        }).flatten);
    };
};
// The numeric values, plus how many LAYOUT keys are unsaved (device, tracks) — those
// have no slider, but the Save button still has to count them.
~sendConfig = {
    ~settingsSpec !? {
        var dirty  = ~settingsDirty ? [];
        var layout = (~layoutKeys ? []).count { |k| dirty.any { |d| d == k } };
        ~dash.sendMsg('/config', layout, *~settingsSpec.collect({ |e|
            [e[\key].asString, (currentEnvironment[e[\key]] ? 0).asFloat,
                dirty.any({ |k| k == e[\key] }).binaryValue]
        }).flatten);
    };
};
OSCdef(\cmdGetConfig, { ~sendConfigSpec.(); ~sendConfig.() }, '/cmd/getConfig').fix;
OSCdef(\cmdSetConfig, { |msg|
    ~settingsSet !? { ~settingsSet.(msg[1].asString, msg[2].asFloat); ~sendConfig.() };
}, '/cmd/setConfig').fix;
OSCdef(\cmdSaveConfig, { |msg|
    var n = ~settingsSave !? { ~settingsSave.() };
    ~dash.sendMsg('/configSaved', (n ? -1).asInteger);
    ~sendConfig.();
}, '/cmd/saveConfig').fix;
OSCdef(\cmdReloadConfig, { |msg|
    ~settingsReload !? { ~settingsReload.() };
    ~sendConfig.(); ~sendRig.();
}, '/cmd/reloadConfig').fix;

// A browser connecting mid-set needs the full picture at once, not on the next change.
OSCdef(\cmdGetTracks, {
    ~sendTracks.(); ~sendState.(); ~sendLevels.(); ~sendFx.(); ~sendCycles.(); ~sendClock.();
    ~sendPins.(); ~sendConfigSpec.(); ~sendConfig.(); ~sendRig.(); ~sendDevices.();
    ~sendVsts.(); ~sendVstPlugins.(); ~sendVstLevels.(); ~sendMidiSources.();
}, '/cmd/getTracks').fix;

// ── State TO the dashboard ──────────────────────────────────
// A clock REFERENCE, not a stream of frames. The browser gets cps + the phase at send
// time and extrapolates the rest itself in requestAnimationFrame. The whole cycle count
// rides along so the strips can place each loop's play head (a 4-bar loop is at
// cycle % 4) without any per-frame traffic.
~sendClock = {
    var cps   = (~cps ? 0.5).asFloat;
    var cycle = ((~lastCycle ? 0)
        + ((Main.elapsedTime - (~lastEventTime ? Main.elapsedTime)) * cps)).asFloat;
    ~dash.sendMsg('/clock', cps, (cycle % 1).asFloat, (~clickDiv ? 4).asInteger, cycle);
};

// Discrete state — only sent when it actually changes.
// The two mixer levels ride along here because they are low-rate and the selection can
// now land on them, so the dashboard has to show them moving.
~sendState = {
    ~dash.sendMsg('/state', (~focus ? 0).asInteger, (~clickOn ? false).binaryValue,
        (~clickAmp ? 0.5).asFloat, (~dirtLevel ? 1.0).asFloat,
        *(~tracks ? []).collect({ |t| (t[\state] ? \idle).asString }));
};

// Which tracks are pinned into the selection. Sent as a flag per track rather than a
// list of indices, so an empty selection is still a well-formed message with a known
// length instead of a bare address the browser has to special-case.
~sendPins = {
    var pins = ~pinned ? [];
    ~dash.sendMsg('/pins', *(~tracks ? []).collect({ |t, i| pins.any({ |k| k == i }).binaryValue }));
};

// Loop length per track, in bars.
~sendCycles = {
    ~dash.sendMsg('/cycles', *(~tracks ? []).collect({ |t| (t[\cycles] ? 4).asInteger }));
};

// Fader positions. Separate from /state because levels move for a different reason
// (a hardware knob) and on a different rhythm — a knob sweep is many small changes,
// a state change is one. Keeping them apart avoids re-sending either needlessly.
~sendLevels = {
    ~dash.sendMsg('/levels', *(~tracks ? []).collect({ |t| (t[\level] ? 1.0).asFloat }));
};

// Drive amounts. Separate from /levels because they move on a completely different
// rhythm — a trigger sweep is a burst, a fader is occasional.
~sendFx = {
    ~dash.sendMsg('/fx', *(~tracks ? []).collect({ |t| (t[\fx] ? 0).asFloat }));
};

// Input and loop level per track, interleaved [in, out, in, out, ...]. One packet per
// tick however many tracks there are, and only while subscribed.
~sendMeters = {
    ~dash.sendMsg('/meters', *(~tracks ? []).collect({ |t|
        [(t[\inAmp] ? 0).asFloat, (t[\outAmp] ? 0).asFloat]
    }).flatten);
    // instruments on their own address, one value each, only when there are any
    if ((~vsts ? []).notEmpty) {
        ~dash.sendMsg('/vstMeters', *~vsts.collect({ |i| (i[\outAmp] ? 0).asFloat }));
    };
};

// ~dashGen makes a stale streamer self-terminate if this file is re-evaluated.
// Wrapped in a function so CmdPeriod can restart it: Ctrl+. clears SystemClock, which
// would otherwise leave the dashboard frozen on its last frame.
//
// The old version pushed /tick AND /trackStates 30x a second — 60 packets/s forever,
// rebuilding an Array and a String per track every frame to report values that change
// a couple of times a minute. And because the phase was sampled at 30 Hz, the browser
// metronome jittered against the display's refresh.
//
// Now the clock reference goes out twice a second (the browser interpolates, so it
// renders SMOOTHER than before) and discrete state is polled cheaply — comparing
// symbols, allocating nothing — and sent only on a real change, so buttons stay
// instant. Idle traffic: ~60 msg/s -> ~2. Meters are the one deliberate exception, and
// only while a visible dashboard keeps asking for them.
~startDashTask !? { CmdPeriod.remove(~startDashTask) };   // don't stack on re-eval
~startDashTask = {
    ~dashGen = (~dashGen ? 0) + 1;
    ~dashRoutine !? { ~dashRoutine.stop };
    ~dashRoutine = Task({
        var myGen = ~dashGen;
        var clockEvery = 0.5, pollEvery = 1/20;
        var tracks, n = -1;
        var lastStates, lastLevels, lastFx, lastCycles;
        var lastPins = nil, pinned, lastLayout = nil, lastBoot = nil, lastScan = nil;
        var lastVst = nil, lastVstLevels = nil, vstLevels, lastMidi = nil, lastMidiAct = nil;
        var lastFocus = nil, lastClick = nil, nextClock = 0, nextMeter = 0;
        var changed, moved, driven, rebar, now;
        while({ myGen == ~dashGen }, {
            now     = Main.elapsedTime;
            tracks  = ~tracks ? [];
            changed = (lastFocus != (~focus ? 0))
                or: { lastClick != [(~clickOn ? false), (~clickAmp ? 0.5), (~dirtLevel ? 1.0)] };
            moved   = false;
            driven  = false;
            rebar   = false;
            // the strips themselves changed shape — first run, a reload, add/remove/rename
            if ((tracks.size != n) or: { lastLayout != ~layoutGen }) {
                n          = tracks.size;
                lastLayout = ~layoutGen;
                lastStates = Array.fill(n, \none);
                lastLevels = Array.fill(n, -1);
                lastFx     = Array.fill(n, -1);
                lastCycles = Array.fill(n, -1);
                lastPins   = nil;
                rebar      = true;
                changed    = true;
                moved      = true;
                driven     = true;
                ~sendTracks.();
                ~sendConfig.();          // the layout's unsaved count lives in /config
            };
            tracks.do { |t, i|
                if (t[\state] != lastStates[i]) { lastStates[i] = t[\state]; changed = true };
                // exact compare is right here: ~trackLevel stores the value verbatim, so
                // this only fires on a real move, not on float noise
                if ((t[\level] ? 1.0) != lastLevels[i]) {
                    lastLevels[i] = t[\level] ? 1.0;
                    moved = true;
                };
                if ((t[\fx] ? 0) != lastFx[i]) { lastFx[i] = t[\fx] ? 0; driven = true };
                if ((t[\cycles] ? 4) != lastCycles[i]) {
                    lastCycles[i] = t[\cycles] ? 4;
                    rebar = true;
                };
            };
            if (changed) {
                lastFocus = ~focus ? 0;
                lastClick = [(~clickOn ? false), (~clickAmp ? 0.5), (~dirtLevel ? 1.0)];
                ~sendState.();
            };
            // pins move on a keypress, not continuously — compare the sorted list
            pinned = (~pinned ? []).sort;
            if (pinned != lastPins) { lastPins = pinned; ~sendPins.() };
            if (moved)  { ~sendLevels.() };
            if (driven) { ~sendFx.() };
            if (rebar)  { ~sendCycles.() };
            if (lastBoot != ~bootGen) { lastBoot = ~bootGen; ~sendRig.() };
            if (lastScan != ~scanGen) { lastScan = ~scanGen; ~sendDevices.(); ~sendRig.() };
            // instruments: the list / a plugin's state / the MIDI target, then levels
            if (lastVst != ~vstGen) {
                lastVst = ~vstGen; ~sendVsts.(); ~sendVstPlugins.(); ~sendVstLevels.(); ~sendConfig.();
            };
            if (lastMidi != ~midiGen) { lastMidi = ~midiGen; ~sendMidiSources.(); ~sendVsts.() };
            if (lastMidiAct != ~midiActivityGen) { lastMidiAct = ~midiActivityGen; ~sendMidiActivity.() };
            vstLevels = (~vsts ? []).collect { |i| i[\level] ? 1.0 };
            if (vstLevels != lastVstLevels) { lastVstLevels = vstLevels; ~sendVstLevels.() };
            if (now >= nextClock) { nextClock = now + clockEvery; ~sendClock.() };
            // meters: stream at ~meterRate while subscribed, and drop the subscription
            // ourselves when the browser stops renewing it
            if (~metersOn ? false) {
                if (now > ~meterUntil) {
                    ~setMeters.(false);
                } {
                    if (now >= nextMeter) {
                        nextMeter = now + (1 / (~meterRate ? 12).max(1));
                        ~sendMeters.();
                    };
                };
            };
            pollEvery.wait;
        });
    }).play(SystemClock);
};
CmdPeriod.add(~startDashTask);
~startDashTask.();

"=== dashboard.scd loaded — bridge: node dashboard/server.js → http://localhost:3000 ===".postln;
