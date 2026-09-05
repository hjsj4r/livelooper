// ============================================================
//  LIVE LOOPER · dashboard.scd
//  Streams live state to the web dashboard and receives its commands.
//  Loaded by startup.scd after looper.scd + click.scd.
//
//  Start the bridge:  node d:/livelooper/dashboard/server.js
//  Then open:         http://localhost:3000
// ============================================================

~dashPort ?? {
    Error("dashboard.scd: config.scd has not been loaded. Evaluate startup.scd instead.").throw
};
~dash = NetAddr("127.0.0.1", ~dashPort);   // the Node bridge listens here for state

// ── Sample preview ──────────────────────────────────────────
// Audition any loaded SuperDirt sample from sclang:  ~preview.("tabla", 3)
// (Also the backend the dashboard sample browser will call in Phase 2.)
// Two defs registered once, rather than `{ ... }.play` — which compiles and ships a
// fresh SynthDef to the server on EVERY click, adding latency and garbage to what
// should be an instant audition. PlayBuf's channel count is fixed at build time, hence
// one def per case.
SynthDef(\preview1, { |buf = 0|
    Out.ar(0, PlayBuf.ar(1, buf, BufRateScale.kr(buf), doneAction: 2) ! 2);
}).add;
SynthDef(\preview2, { |buf = 0|
    Out.ar(0, PlayBuf.ar(2, buf, BufRateScale.kr(buf), doneAction: 2));
}).add;

~preview = { |bank, idx = 0|
    var bufs = ~dirt.buffers[bank.asSymbol];
    if (bufs.isNil) {
        ("No such bank: " ++ bank).postln;
    } {
        var buf = bufs.wrapAt(idx);
        Synth((buf.numChannels == 1).if({ \preview1 }, { \preview2 }), [buf: buf]);
        ("preview " ++ bank ++ ":" ++ idx ++ "  (" ++ bufs.size ++ " in bank)").postln;
    };
};

// ── Commands FROM the dashboard ─────────────────────────────
// The bridge forwards browser commands as OSC to sclang on :57120.
// Every one is .fix'ed — responders are freed by Ctrl+. otherwise, which would leave the
// dashboard visibly connected but completely inert.
OSCdef(\cmdTrackRecord,  { |msg| ~tracks[msg[1].asInteger] !? { |t| ~trackRecord.(t) } },  '/cmd/trackRecord').fix;
OSCdef(\cmdTrackOverdub, { |msg| ~tracks[msg[1].asInteger] !? { |t| ~trackOverdub.(t) } }, '/cmd/trackOverdub').fix;
OSCdef(\cmdTrackClear, { |msg| ~tracks[msg[1].asInteger] !? { |t| ~trackClear.(t) } }, '/cmd/trackClear').fix;
OSCdef(\cmdTrackLevel, { |msg| ~tracks[msg[1].asInteger] !? { |t| ~trackLevel.(t, msg[2].asFloat) } }, '/cmd/trackLevel').fix;
// R2 pressure. Arrives often while the trigger moves, so the handler stays trivial.
OSCdef(\cmdTrackFx,    { |msg| ~tracks[msg[1].asInteger] !? { |t| ~trackFx.(t, msg[2].asFloat) } }, '/cmd/trackFx').fix;
OSCdef(\cmdFocus,      { |msg| ~navFocus.(msg[1].asInteger) }, '/cmd/focus').fix;

// The per-strip buttons above act on ONE track — the one whose button you clicked.
// The controller acts on the SELECTION (pinned tracks plus the focused one), which is
// why these are separate addresses rather than a flag on the same ones: a mouse click on
// a strip should never quietly fire on four tracks because something was pinned.
OSCdef(\cmdSelRecord,  { ~selDo.("record",  { |t| ~trackRecord.(t) })  }, '/cmd/selRecord').fix;
OSCdef(\cmdSelOverdub, { ~selDo.("overdub", { |t| ~trackOverdub.(t) }) }, '/cmd/selOverdub').fix;
OSCdef(\cmdSelClear,   { ~selDo.("clear",   { |t| ~trackClear.(t) })   }, '/cmd/selClear').fix;
OSCdef(\cmdSelLoop,    { ~selDo.("stop/start", { |t| ~trackLoopToggle.(t) }) },
    '/cmd/selLoopToggle').fix;
OSCdef(\cmdPinToggle,  { |msg| ~pinToggle.(if (msg.size > 1) { msg[1].asInteger }) },
    '/cmd/pinToggle').fix;
OSCdef(\cmdPinClear,   { ~pinClear.() }, '/cmd/pinClear').fix;
// From the DualSense, relayed by the browser's Gamepad API through the bridge.
OSCdef(\cmdNavMove,    { |msg| ~navMove.(msg[1].asInteger) }, '/cmd/navMove').fix;
// Left/right on the stick — nudges whatever the selection is sitting on, tracks and the
// two mixer items alike.
OSCdef(\cmdNavAdjust,  { |msg| ~navAdjust.(msg[1].asFloat) }, '/cmd/navAdjust').fix;
OSCdef(\cmdTrackCycles, { |msg|
    ~tracks[msg[1].asInteger] !? { |t|
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

// Track config → the dashboard builds its strips from this. Sent as name/input PAIRS so
// the two can't drift out of alignment, and as strings because a stereo track is fed by
// two inputs and reads as "0+1".
~sendTracks = {
    ~dash.sendMsg('/tracksInit', ~tracks.size,
        *~tracks.collect({ |t| [t[\name].asString, ~inLabel.(t).asString] }).flatten);
};
// A browser connecting mid-set needs the full picture at once, not on the next change.
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
~sendConfig = {
    ~settingsSpec !? {
        ~dash.sendMsg('/config', *~settingsSpec.collect({ |e|
            [e[\key].asString, (currentEnvironment[e[\key]] ? 0).asFloat,
                (~settingsDirty ? []).any({ |k| k == e[\key] }).binaryValue]
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
    ~sendConfig.();
}, '/cmd/reloadConfig').fix;

OSCdef(\cmdGetTracks, {
    ~sendTracks.(); ~sendState.(); ~sendLevels.(); ~sendFx.(); ~sendCycles.(); ~sendClock.();
    ~sendPins.(); ~sendConfigSpec.(); ~sendConfig.();
}, '/cmd/getTracks').fix;

// ── Sample browser backend ──────────────────────────────────
// Send the loaded banks (name, count, name, count, ...) to the dashboard.
~sendBanks = {
    var names = ~dirt.buffers.keys.asArray.collect(_.asString).sort;
    ~dash.sendMsg('/banksClear');
    names.clump(40).do { |chunk|          // small messages avoid oversized-packet issues
        var flat = Array.new;
        chunk.do { |name| flat = flat.add(name).add(~dirt.buffers[name.asSymbol].size.asInteger) };
        ~dash.sendMsg('/banksAdd', *flat);
    };
    ~dash.sendMsg('/banksDone', names.size);
    ("sent " ++ names.size ++ " banks (chunked) to dashboard").postln;
};
OSCdef(\cmdGetBanks, { |msg| ~sendBanks.() }, '/cmd/getBanks').fix;
OSCdef(\cmdPreview,  { |msg| ~preview.(msg[1].asString, msg[2].asInteger) }, '/cmd/preview').fix;

// ── State TO the dashboard ──────────────────────────────────
// A clock REFERENCE, not a stream of frames. The browser gets cps + the phase at send
// time and extrapolates the rest itself in requestAnimationFrame.
~sendClock = {
    var cps   = (~cps ? 0.5).asFloat;
    var phase = (((~lastCycle ? 0)
        + ((Main.elapsedTime - (~lastEventTime ? Main.elapsedTime)) * cps)) % 1).asFloat;
    ~dash.sendMsg('/clock', cps, phase, (~clickDiv ? 4).asInteger);
};

// Discrete state — only sent when it actually changes.
// The two mixer levels ride along here because they are low-rate and the selection can
// now land on them, so the dashboard has to show them moving.
~sendState = {
    ~dash.sendMsg('/state', (~focus ? 0).asInteger, (~clickOn ? false).binaryValue,
        (~clickAmp ? 0.5).asFloat, (~dirtLevel ? 1.0).asFloat,
        *~tracks.collect({ |t| (t[\state] ? \idle).asString }));
};

// Which tracks are pinned into the selection. Sent as a flag per track rather than a
// list of indices, so an empty selection is still a well-formed message with a known
// length instead of a bare address the browser has to special-case.
~sendPins = {
    var pins = ~pinned ? [];
    ~dash.sendMsg('/pins', *~tracks.collect({ |t, i| pins.any({ |k| k == i }).binaryValue }));
};

// Loop length per track, in bars.
~sendCycles = {
    ~dash.sendMsg('/cycles', *~tracks.collect({ |t| (t[\cycles] ? 4).asInteger }));
};

// Fader positions. Separate from /state because levels move for a different reason
// (a hardware knob) and on a different rhythm — a knob sweep is many small changes,
// a state change is one. Keeping them apart avoids re-sending either needlessly.
~sendLevels = {
    ~dash.sendMsg('/levels', *~tracks.collect({ |t| (t[\level] ? 1.0).asFloat }));
};

// Drive amounts. Separate from /levels because they move on a completely different
// rhythm — a trigger sweep is a burst, a fader is occasional.
~sendFx = {
    ~dash.sendMsg('/fx', *~tracks.collect({ |t| (t[\fx] ? 0).asFloat }));
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
// instant. Idle traffic: ~60 msg/s -> ~2.
~startDashTask !? { CmdPeriod.remove(~startDashTask) };   // don't stack on re-eval
~startDashTask = {
    ~dashGen = (~dashGen ? 0) + 1;
    ~dashRoutine !? { ~dashRoutine.stop };
    ~dashRoutine = Task({
        var myGen = ~dashGen;
        var clockEvery = 0.5, pollEvery = 1/20;
        var lastStates = Array.fill(~tracks.size, \none);
        var lastLevels = Array.fill(~tracks.size, -1);
        var lastFx     = Array.fill(~tracks.size, -1);
        var lastCycles = Array.fill(~tracks.size, -1);
        var lastPins = nil, pinned;
        var lastFocus = nil, lastClick = nil, nextClock = 0, changed, moved, driven, rebar, now;
        while({ myGen == ~dashGen }, {
            now     = Main.elapsedTime;
            changed = (lastFocus != (~focus ? 0))
                or: { lastClick != [(~clickOn ? false), (~clickAmp ? 0.5), (~dirtLevel ? 1.0)] };
            moved   = false;
            driven  = false;
            if (~tracks.size != lastStates.size) {          // track count changed
                lastStates = Array.fill(~tracks.size, \none);
                lastLevels = Array.fill(~tracks.size, -1);
                lastFx     = Array.fill(~tracks.size, -1);
                lastCycles = Array.fill(~tracks.size, -1);
                rebar      = true;
                changed    = true;
                moved      = true;
                driven     = true;
            };
            ~tracks.do { |t, i|
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
            if (now >= nextClock) { nextClock = now + clockEvery; ~sendClock.() };
            pollEvery.wait;
        });
    }).play(SystemClock);
};
CmdPeriod.add(~startDashTask);
~startDashTask.();

"=== dashboard.scd loaded — bridge: node dashboard/server.js → http://localhost:3000 ===".postln;
