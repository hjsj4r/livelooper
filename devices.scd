// ============================================================
//  LIVE LOOPER · devices.scd
//  Finds the audio interfaces on this machine, with their channel counts, and moves the
//  running rig onto one of them.
//  Loaded by startup.scd BEFORE the server boots, so a rig whose configured interface is
//  unplugged can still be steered onto another one from the dashboard.
//
//    ~scanDevices.();            // async; fills ~devices and posts them
//    ~devices                    // [(name:, ins:, outs:), ...]
//    ~useDevice.("ASIO : ZOOM H8 Audio Driver");                    // in = out
//    ~useDevice.("Windows WASAPI : Mic", "Windows WASAPI : Speakers", 48000);
//
//  WHY A THROWAWAY SCSYNTH
//  sclang's own API (ServerOptions.devices / inDevices / outDevices) returns NAMES only.
//  The one thing that knows how many channels each device has is scsynth itself, which
//  prints the whole table — "(12 ins, 2 outs)" per device — every time it boots. So the
//  scan boots a second scsynth on a spare port with a sample rate no device can accept
//  (-S 1): it enumerates everything, fails at Pa_OpenStream, and exits on its own in
//  well under a second. The running server never notices. unixCmd is non-blocking, so
//  the click keeps ticking; the output goes through a file because there is no way to
//  read a child's stdout from sclang without blocking the interpreter.
//
//  WHY SWITCHING IS A REBOOT
//  Device, sample rate and channel counts are server OPTIONS: scsynth opens the stream
//  once, at boot. There is no "change device" message. So ~useDevice quits the server,
//  sets the options and boots again — and everything that survives Ctrl+. survives this
//  too, because the same ServerQuit / ServerTree hooks do the teardown and the rebuild.
//  Loops do NOT survive (buffers die with the server); the track LAYOUT does.
// ============================================================

~scanPort ?? {
    Error("devices.scd: config.scd has not been loaded. Evaluate startup.scd instead.").throw
};

~devices   = ~devices ? [];
~bootState = ~bootState ? \off;      // \off \booting \ready \failed — mirrored to the dashboard
~bootMsg   = ~bootMsg ? "";

~setBootState = { |state, msg|
    ~bootState = state;
    ~bootMsg   = (msg ? "").asString;
    ~bootGen   = (~bootGen ? 0) + 1;          // the dashboard task sends /rig on change
};

// The scan's table, parsed. Only lines of the form
//     - <name>
//       (<n> ins, <m> outs)
// count; everything else scsynth prints around them is ignored.
~parseDeviceScan = { |text|
    var devs = [], cur;
    text.split($\n).do { |raw|
        var l = raw.stripWhiteSpace;
        if (l.beginsWith("- ")) { cur = (name: l[2..].stripWhiteSpace) };
        if (l.beginsWith("(") and: { l.endsWith("outs)") } and: { cur.notNil }) {
            var parts = l[1 .. l.size - 2].split($,);       // ["12 ins", " 2 outs"]
            if (parts.size == 2) {
                cur[\ins]  = parts[0].stripWhiteSpace.asInteger;
                cur[\outs] = parts[1].stripWhiteSpace.asInteger;
                devs = devs.add(cur);
            };
            cur = nil;
        };
    };
    devs;
};

// Runs the throwaway server and hands the parsed list to `done` (and leaves it in
// ~devices). `done` gets an empty list if the scan produced nothing — a missing scsynth,
// a port in use — and the reason is in the post window.
~scanDevices = { |done|
    var exe  = Platform.resourceDir +/+ "scsynth" ++ if (thisProcess.platform.name == \windows) { ".exe" } { "" };
    var out  = PathName.tmp +/+ "livelooper-devices.txt";
    var cmd, t0 = Main.elapsedTime;
    if (File.exists(exe).not) {
        ("~scanDevices: scsynth not found at " ++ exe).warn;
        ~devices = [];
        done.value(~devices);
    } {
        // cmd /c so the redirect is honoured; the outer quotes are what cmd needs to
        // keep a quoted path AND a quoted redirect target in one command line.
        cmd = "cmd /c \"\"" ++ exe ++ "\" -u " ++ ~scanPort ++ " -S 1 -i 2 -o 2 > \""
            ++ out ++ "\" 2>&1\"";
        if (thisProcess.platform.name != \windows) {
            cmd = "\"" ++ exe ++ "\" -u " ++ ~scanPort ++ " -S 1 -i 2 -o 2 > \"" ++ out ++ "\" 2>&1";
        };
        ~scanning = true;
        cmd.unixCmd({ |code|
            var text = if (File.exists(out)) { File.readAllString(out) } { "" };
            ~devices  = ~parseDeviceScan.(text);
            ~scanning = false;
            ~scanGen  = (~scanGen ? 0) + 1;         // the dashboard task sends /devices
            if (~devices.isEmpty) {
                ("~scanDevices: scsynth exited (" ++ code ++ ") without listing any device"
                    ++ " — see " ++ out).warn;
            } {
                ("devices: " ++ ~devices.size ++ " found in "
                    ++ (Main.elapsedTime - t0).round(0.01) ++ "s").postln;
                ~devices.do { |d|
                    ("    " ++ d[\name] ++ "   (" ++ d[\ins] ++ " in, " ++ d[\outs] ++ " out)").postln;
                };
            };
            done.value(~devices);
        }, false);
    };
};

// The device the rig is configured to use, as an (inDevice, outDevice) pair — the shape
// the server wants. ~audioDevice, when set, wins for both halves.
~configuredDevices = {
    if (~audioDevice.notNil) { [~audioDevice, ~audioDevice] } { [~inDevice, ~outDevice] };
};

// Copy config -> s.options. Called before every boot, so that config is the ONLY place a
// device decision lives; the server never quietly keeps a stale one.
~applyServerOptions = {
    var pair = ~configuredDevices.();
    s.options.inDevice             = pair[0];
    s.options.outDevice            = pair[1];
    s.options.sampleRate           = ~sampleRate;
    s.options.numInputBusChannels  = ~numInputs;
    s.options.numOutputBusChannels = ~numOutputs;
    s.options.numBuffers           = ~numBuffers;
    s.options.memSize              = ~memSize;
};

// Is this name absent from what the OS offers? nil (system default) is always present.
//
// NOTE: `.any { |d| d == name }`, NOT `.includes(name)`. ArrayedCollection's
// includes/indexOf compare by IDENTITY, so they never match a String however identical
// its contents. This check used to reject the correct, present device and refuse to boot.
~deviceMissing = { |name, list|
    name.notNil and: { (list ? ServerOptions.devices).any { |d| d == name }.not }
};

// A readable report instead of a hung boot. Windows enumerates 200+ MME/DirectSound/
// WDM-KS endpoints, and dumping them all buries the actual error off the top of the post
// window, so narrow to the driver class that was asked for ("ASIO : ..." -> ASIO).
~postMissingDevice = { |name|
    var all, api, same, cap = 24;
    all  = ServerOptions.devices;
    api  = name.asString.split($:).first.stripWhiteSpace;
    same = all.select { |d| d.asString.beginsWith(api) };
    if (same.isEmpty) { same = all };
    "".postln;
    ("*** Audio device not found: " ++ name.asCompileString).postln;
    ("*** " ++ same.size ++ " device(s) under " ++ api.asCompileString
        ++ ", of " ++ all.size ++ " endpoints total:").postln;
    same.keep(cap).do { |d| ("      " ++ d.asCompileString).postln };
    if (same.size > cap) { ("      ... and " ++ (same.size - cap) ++ " more").postln };
    "***   Yours missing? The interface is unplugged or its driver isn't loaded.".postln;
    "***   Pick another from the dashboard's Setup view, or set ~audioDevice in config.scd".postln;
    "***   (nil = system default) and evaluate startup.scd again.".postln;
    "".postln;
};

// Boot on whatever config says. `onReady` runs once the server is up (inside a Routine,
// so it may s.sync). A missing device reports and returns false instead of hanging on a
// boot that never completes — waitForBoot would simply never fire.
~bootRig = { |onReady|
    var pair = ~configuredDevices.();
    var bad  = [[pair[0], ServerOptions.inDevices], [pair[1], ServerOptions.outDevices]]
        .detect { |x| ~deviceMissing.(x[0], x[1]) };
    if (bad.notNil) {
        ~postMissingDevice.(bad[0]);
        ~setBootState.(\failed, "device not found: " ++ bad[0]);
        false;
    } {
        ~applyServerOptions.();
        ~setBootState.(\booting, "booting on " ++ (pair[0] ? "system default"));
        s.waitForBoot({
            onReady.value;
            ~setBootState.(\ready, "");
        }, onFailure: {
            ~setBootState.(\failed, "server failed to boot — see the post window");
        });
        true;
    };
};

// Move the running rig to another interface. Everything is optional: a nil device is
// the system default, a nil rate lets the device choose, and channel counts default to
// what the scan reported for that device (plus a floor of 2 outputs, since the click
// needs a right channel to hide on).
//
// The choice goes into the config variables first and is marked unsaved, exactly like a
// settings slider: Save writes it to config.scd, a restart without saving forgets it.
~useDevice = { |inName, outName, rate, ins, outs|
    var inDev  = if (inName.isNil or: { inName.asString.isEmpty }) { nil } { inName.asString };
    var outDev = if (outName.isNil or: { outName.asString.isEmpty }) { inDev } { outName.asString };
    var info   = { |n| ~devices.detect { |d| d[\name] == n } };
    var bad;
    // Refuse before touching anything: a rig that is playing must not be quit for a
    // device that cannot be opened.
    bad = [[inDev, ServerOptions.inDevices], [outDev, ServerOptions.outDevices]]
        .detect { |x| ~deviceMissing.(x[0], x[1]) };
    if (bad.notNil) {
        ~postMissingDevice.(bad[0]);
        ~setBootState.(~bootState, "device not found: " ++ bad[0]);   // state unchanged, message shown
        false;
    } {
        if (inDev == outDev) {
            ~audioDevice = inDev; ~inDevice = nil; ~outDevice = nil;
        } {
            ~audioDevice = nil; ~inDevice = inDev; ~outDevice = outDev;
        };
        ~sampleRate = if (rate.isNil or: { rate.asInteger <= 0 }) { nil } { rate.asInteger };
        ~numInputs  = (ins  ? (info.(inDev)  !? { |d| d[\ins]  }) ? ~numInputs).asInteger.max(1);
        ~numOutputs = (outs ? (info.(outDev) !? { |d| d[\outs] }) ? ~numOutputs).asInteger.max(2);
        ~settingsMarkDirty !? {
            [\audioDevice, \inDevice, \outDevice, \sampleRate, \numInputs, \numOutputs]
                .do { |k| ~settingsMarkDirty.(k) };
        };
        ("devices: switching to in " ++ (inDev ? "default").asCompileString
            ++ " / out " ++ (outDev ? "default").asCompileString
            ++ " @ " ++ (~sampleRate ? "device rate") ++ ", "
            ++ ~numInputs ++ " in, " ++ ~numOutputs ++ " out").postln;
        ~rebootRig.();
        true;
    };
};

// Quit (if running) and boot again on the current config. The ServerQuit hooks forget
// SuperDirt and the track buffers; ~bootAll then rebuilds everything from config — the
// same code path as the first boot of the day, so there is only one to get right.
//
// Quit's completion callback is where the boot goes, NOT s.reboot: reboot boots on its
// own AND we need waitForBoot to run ~bootAll, and two boots in flight at once is a
// "server already booting" mess. This way the sequence is quit -> options -> boot -> rig.
//
// THE QUIT CAN FAIL AND STILL SUCCEED. scsynth on Windows sometimes dies with an access
// violation while closing a PortAudio stream (MME/WASAPI especially) — it posts "exited
// with exit code -1073741819" and never sends the /done that quit's completion callback
// waits for. The process is gone, which is all a reboot needs, but left alone that
// callback never fires and the rig stays down. So the failure callback (3 s later)
// checks whether the server is actually still there, and boots if it is not.
// And sclang's quit watcher has a second hole: if the server was never `notified`, it
// registers NO watcher at all and neither callback ever runs. So a watchdog of our own
// checks a beat after quit's own 3 s deadline: nothing has happened and the process is
// gone -> boot. (~quitServer is a seam: test/devices-test.scd stubs it with a quit whose
// callbacks never return, which is the symptom, and the watchdog has to recover.)
~quitServer = ~quitServer ? { |onDone, onFail| s.quit(onDone, onFail) };
~rebootWatchdogSecs = 4.0;
~rebootRig = {
    var gen, done = false, go;
    ~bootAll ?? {
        Error("~rebootRig: ~bootAll is not defined. Evaluate startup.scd instead.").throw
    };
    ~rebootGen = (~rebootGen ? 0) + 1;
    gen = ~rebootGen;
    go  = { if (done.not) { done = true; ~bootRig.(~bootAll) } };
    ~setBootState.(\booting, "restarting the server...");
    if (s.serverRunning) {
        ~quitServer.(go, {
            if (s.serverRunning.not) {
                "devices: the server crashed on the way out — booting anyway".postln;
                go.();
            } {
                ~setBootState.(\failed, "the server did not quit — see the post window");
            };
        });
        SystemClock.sched(~rebootWatchdogSecs, {
            if (done.not and: { gen == ~rebootGen }) {
                if (s.serverRunning.not) {
                    "devices: no answer to /quit but the server is gone — booting anyway".postln;
                    go.();
                } {
                    ~setBootState.(\failed, "the server did not quit — see the post window");
                };
            };
            nil;
        });
    } {
        go.();
    };
};

"=== devices.scd loaded — ~scanDevices.() lists interfaces, ~useDevice.(name) switches ===".postln;
