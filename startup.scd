// ============================================================
//  LIVE LOOPER  ·  startup.scd
//  TidalCycles + SuperCollider
//
//  DAILY START — ONE evaluation:
//    Click anywhere inside the parens below, press Ctrl+Enter,
//    wait for "=== LIVE LOOPER READY ===",
//    then in VS Code: Tidal: Boot.
//
//  Settings live in config.scd — you should not need to edit this file.
//  Re-evaluating is safe and fast: it reloads the code without re-scanning the
//  sample library and without interrupting audio.
// ============================================================

(
var bootAll;

// Project folder, derived from this file's own location, so the folder can be moved or
// cloned anywhere. Works both when evaluated in the IDE and when .load'ed.
~projectDir = thisProcess.nowExecutingPath !? { |p| p.dirname ++ "/" };
~projectDir ?? {
    ~projectDir = "D:/livelooper/";
    ("startup.scd: could not derive the project path (unsaved document?) — falling back to "
        ++ ~projectDir).warn;
};

(~projectDir ++ "config.scd").load;

s.options.device               = ~audioDevice;
s.options.sampleRate           = ~sampleRate;
s.options.numInputBusChannels  = ~numInputs;
s.options.numOutputBusChannels = ~numOutputs;
s.options.numBuffers           = ~numBuffers;
s.options.memSize              = ~memSize;


bootAll = {
    var t0;

    // Dirt-Samples sits next to the SuperDirt quark.
    ~dirtSamplesDir = SuperDirt.filenameSymbol.asString.dirname.dirname.dirname
        +/+ "Dirt-Samples";

    // Pull banks in by name — at boot from ~sampleBanks, or later mid-session without
    // restarting anything. Loading a bank only replaces one of the SAME name, so this
    // adds to the library rather than resetting it.
    ~loadBanks = { |banks|
        banks.asArray.do { |b|
            var path = ~dirtSamplesDir +/+ b.asString;
            if (File.exists(path)) {
                ~dirt.loadSoundFileFolder(path, b.asSymbol);
            } {
                ("~loadBanks: no such bank in Dirt-Samples: " ++ b).warn;
            };
        };
        ~sendBanks !? { ~sendBanks.() };          // refresh the dashboard browser
    };

    // Load the configured library + anything in samples/.
    ~loadAllSamples = {
        if (~sampleBanks.isNil) { ~dirt.loadSoundFiles } { ~loadBanks.(~sampleBanks) };
        if (PathName(~projectDir ++ "samples/").folders.size > 0) {
            ~dirt.loadSoundFiles(~projectDir ++ "samples/*");
        };
    };

    // SuperDirt is built ONCE. Re-evaluating this file then only reloads the code
    // instead of re-scanning the whole sample library, which keeps the edit loop fast
    // and leaves audio running. A server quit or reboot clears ~dirt (ServerQuit hook
    // below), so the next evaluation rebuilds it properly.
    //
    // NOTE: the INSTANCE method is used on purpose. The SuperDirt.start CLASS method
    // reboots the server from an OSC thread and throws "yield called outside Routine"
    // on this machine. Do not use it.
    if (~dirt.isNil) {
        ~dirtBus = Bus.audio(s, 2);
        ~dirt    = SuperDirt(2, s);
        // Custom banks: each subfolder of samples/ becomes a sound name. Same-named
        // banks replace the built-in ones; the rest of the library is untouched.
        t0 = Main.elapsedTime;
        ~loadAllSamples.value;
        // All orbits share one private stereo bus, which a master fader synth then
        // copies to the main out. That gives the Tidal patterns their own level knob
        // (~dirtLevel) independent of the loops and click, which write to 0/1 directly.
        ~dirt.start(~dirtPort, ~dirtBus.index ! ~dirtOrbits);
        ("SuperDirt: " ++ ~dirtOrbits ++ " orbits, listening on " ++ ~dirtPort).postln;
        ("samples: " ++ ~dirt.buffers.size ++ " banks, "
            ++ (~dirt.soundLibrary.memoryFootprint / 1e6).round(0.1) ++ " MB, loaded in "
            ++ (Main.elapsedTime - t0).round(0.1) ++ "s"
            ++ (~sampleBanks.isNil).if({ "  (~sampleBanks in config.scd trims this)" }, { "" })
        ).postln;
    } {
        "SuperDirt already running — reusing it. (~reloadSamples.() re-scans samples/)".postln;
    };

    ~dirtLevel = ~dirtLevel ? 1.0;                  // runtime state, survives a reload

    SynthDef(\dirtFader, { |level = 1|
        Out.ar(0, In.ar(\bus.ir(0), 2) * Lag.kr(level, 0.05));  // Lag = click-free fades
    }).add;

    // PANIC SURVIVAL — Ctrl+. (CmdPeriod) runs Server.freeAll, which frees EVERY node,
    // this fader included. SuperDirt rebuilds its own orbits from ServerTree, but those
    // orbits write into ~dirtBus — so without the fader the patterns would keep playing
    // into a bus nobody reads and Tidal would go permanently silent. ServerTree fires
    // right after the node tree is re-initialised, which is exactly where this belongs.
    // addToTail → runs after all SuperDirt orbit synths, so it reads the summed patterns.
    // The ~dirtBus guard matters on a reboot: ServerTree also runs on a fresh boot, when
    // ~forgetDirt has just cleared the bus and nothing has rebuilt it yet.
    ~buildDirtFader !? { ServerTree.remove(~buildDirtFader, s) };  // don't stack on re-eval
    ~buildDirtFader = {
        ~dirtBus !? {
            ~dirtFader = Synth(\dirtFader, [bus: ~dirtBus, level: ~dirtLevel],
                addAction: \addToTail);
        };
    };
    ServerTree.add(~buildDirtFader, s);

    // A server quit/reboot invalidates every buffer, bus and orbit SuperDirt owns, so
    // forget them and let the next evaluation build fresh ones.
    ~forgetDirt !? { ServerQuit.remove(~forgetDirt, s) };
    ~forgetDirt = { ~dirt = nil; ~dirtFader = nil; ~dirtBus = nil };
    ServerQuit.add(~forgetDirt, s);

    // Re-scan without restarting anything — use after adding a bank to samples/.
    ~reloadSamples = {
        ~loadAllSamples.value;
        ~sendBanks !? { ~sendBanks.() };             // refresh the dashboard browser
        "samples reloaded.".postln;
    };

    s.sync;                                          // \dirtFader has landed
    ~dirtFader !? { ~dirtFader.free };               // explicit reload only
    ~buildDirtFader.value;

    (~projectDir ++ "looper.scd").load;
    (~projectDir ++ "click.scd").load;
    (~projectDir ++ "settings.scd").load;
    (~projectDir ++ "dashboard.scd").load;

    "".postln;
    "=== LIVE LOOPER READY ===".postln;
    ("    project: " ++ ~projectDir).postln;
    ("    device:  " ++ (~audioDevice ? "system default")).postln;
    "    next: VS Code -> Tidal: Boot".postln;
};


// A wrong device name makes scsynth fail to start, and waitForBoot would then simply
// never fire — a silent hang right when you need it least. Say what's wrong instead.
// Is the configured device absent? nil (system default) is always fine.
//
// NOTE: `.any { |d| d == name }`, NOT `.includes(name)`. ArrayedCollection's
// includes/indexOf compare by IDENTITY, so they never match a String however identical
// its contents — Symbols, Floats and Integers are immediate values and do match, which
// is what makes the trap so easy to miss. This check used to reject the correct,
// present device and refuse to boot.
~deviceMissing = { |name|
    name.notNil and: { ServerOptions.devices.any { |d| d == name }.not }
};

if (~deviceMissing.(~audioDevice)) {
    var all, api, same, cap = 24;
    // Windows enumerates 200+ MME/DirectSound/WDM-KS endpoints, and dumping them all
    // buries the actual error off the top of the post window. Narrow to the driver
    // class that was actually asked for ("ASIO : ..." -> the ASIO devices).
    all  = ServerOptions.devices;
    api  = ~audioDevice.asString.split($:).first.stripWhiteSpace;
    same = all.select { |d| d.asString.beginsWith(api) };
    if (same.isEmpty) { same = all };

    "".postln;
    ("*** Audio device not found: " ++ ~audioDevice.asCompileString).postln;
    ("*** " ++ same.size ++ " device(s) under " ++ api.asCompileString
        ++ ", of " ++ all.size ++ " endpoints total:").postln;
    same.keep(cap).do { |d| ("      " ++ d.asCompileString).postln };
    if (same.size > cap) { ("      ... and " ++ (same.size - cap) ++ " more").postln };
    "***   Yours missing? The interface is unplugged or its driver isn't loaded.".postln;
    "*** Full list:  ServerOptions.devices.do(_.postln);".postln;
    "*** Then set ~audioDevice in config.scd (nil = system default) and evaluate again.".postln;
    "".postln;
} {
    s.waitForBoot(bootAll);
};
)


// ── Handy ───────────────────────────────────────────────────
// Audio alive?    { SinOsc.ar(440) * 0.1 ! 2 }.play;   // Ctrl+. to stop
// List banks:     ~dirt.postSampleInfo;
// Added samples?  ~reloadSamples.();
// Changed the audio device in config.scd?  s.reboot;  then evaluate the region again.
