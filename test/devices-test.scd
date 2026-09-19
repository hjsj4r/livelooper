// ============================================================
//  LIVE LOOPER · devices-test.scd
//  The rig can list this machine's audio interfaces, with their channel counts, and move
//  onto one of them while running. That last part is a server quit + boot through the
//  same ~bootAll as the first boot of the day, so this test does it for real, twice, on
//  its own server — and checks that what should come back does (tracks, click,
//  SuperDirt) and what must not (a second /dirt/play responder) does not.
//
//  Run it headless (no ZOOM H8 needed — it boots the system default device):
//    & "C:\Program Files\SuperCollider-3.14.1\sclang.exe" -D d:/livelooper/test/devices-test.scd
//
//  Expect: "36 passed, 0 failed".
// ============================================================
(
var pass = 0, fail = 0, ok, canned, devs, scanned = nil, t0, rigs = 0, lastRig, dirtPlays;
var waitFor;

ok = { |label, cond|
    if (cond) { pass = pass + 1; ("  PASS  " ++ label).postln }
             { fail = fail + 1; ("  FAIL  " ++ label).postln };
};
waitFor = { |cond, secs = 20|
    var t = Main.elapsedTime;
    while { cond.value.not and: { (Main.elapsedTime - t) < secs } } { 0.2.wait };
    cond.value;
};
// how many live OSC responders listen for Tidal's events — must be exactly one
dirtPlays = {
    // allFuncProxies is grouped by dispatcher type -> arrays of responders
    AbstractResponderFunc.allFuncProxies.values.flatten.count({ |f|
        f.isKindOf(OSCFunc) and: { f.path == '/dirt/play' }
    });
};

s = Server(\llDevTest, NetAddr("127.0.0.1", 57158));
Server.default = s;

fork {
    // Load startup.scd for its ~bootAll and module loads, but drive the boot from here.
    ~autoBoot = false;
    "D:/livelooper/startup.scd".load;
    ok.("startup.scd defines ~bootAll", ~bootAll.notNil);
    ok.("devices.scd loaded before any boot", ~scanDevices.notNil and: { ~useDevice.notNil });
    ok.("dashboard responders exist before any boot", OSCdef.all[\cmdScanDevices].notNil);

    "".postln; "--- PARSING THE SCAN ---".postln;
    canned = "Device options:\r\n- MME : Some Mic\r\n  (2 ins, 0 outs)\r\n"
        "- ASIO : ZOOM H8 Audio Driver\r\n  (12 ins, 2 outs)\r\n"
        "- junk line without counts\r\n"
        "- Windows WASAPI : Altavoces (Realtek(R) Audio)\r\n  (0 ins, 2 outs)\r\n\r\n"
        "Requested devices:\r\n  In:\r\n  - (default)\r\n";
    devs = ~parseDeviceScan.(canned);
    ok.("three devices parsed",            devs.size == 3);
    ok.("names are exact",                 devs[1][\name] == "ASIO : ZOOM H8 Audio Driver");
    ok.("counts are integers",             devs[1][\ins] == 12 and: { devs[1][\outs] == 2 });
    ok.("a device without counts is skipped", devs.any({ |d| d[\name].contains("junk") }).not);
    ok.("CRLF does not leak into names",   devs[2][\name].endsWith(")"));
    ok.("empty text -> no devices",        ~parseDeviceScan.("").isEmpty);

    "".postln; "--- THE REAL SCAN ---".postln;
    t0 = Main.elapsedTime;
    ~scanDevices.({ |list| scanned = list });
    ok.("scan returns immediately (non-blocking)", scanned.isNil);
    waitFor.({ scanned.notNil }, 30);
    ("        (" ++ (scanned ? []).size ++ " devices in " ++ (Main.elapsedTime - t0).round(0.1) ++ "s)").postln;
    ok.("scan completes",                  scanned.notNil);
    ok.("finds at least one device",       scanned.notNil and: { scanned.size > 0 });
    ok.("every entry has counts",          scanned.notNil and: { scanned.every { |d| d[\ins].isInteger and: { d[\outs].isInteger } } });
    ok.("names match the sclang API's",    scanned.notNil and: {
        scanned.any { |d| ServerOptions.devices.any { |n| n == d[\name] } } });
    ok.("result kept in ~devices",         ~devices === scanned);

    "".postln; "--- REFUSALS ---".postln;
    ~audioDevice = "ASIO : ZOOM H8 Audio Driver";     // as config.scd has it
    ok.("configured pair reads from ~audioDevice", ~configuredDevices.() == [~audioDevice, ~audioDevice]);
    ~audioDevice = nil; ~inDevice = "x"; ~outDevice = "y";
    ok.("...or from the in/out pair",      ~configuredDevices.() == ["x", "y"]);
    ~audioDevice = "__no_such_device__"; ~inDevice = nil; ~outDevice = nil;
    ok.("boot on a missing device refuses", ~bootRig.(~bootAll) == false);
    ok.("...and says so",                  ~bootState == \failed and: { ~bootMsg.contains("not found") });
    ok.("...without leaving a server running", s.serverRunning.not);
    ok.("useDevice on a missing device refuses", ~useDevice.("__no_such_device__") == false);
    ok.("...and leaves the config alone",  ~audioDevice == "__no_such_device__");

    "".postln; "--- BOOT ON THE SYSTEM DEFAULT ---".postln;
    ~sampleBanks = [];                       // no sample library: seconds, not a minute
    ~dirtPort    = NetAddr.langPort;
    ~dashPort    = NetAddr.langPort; ~dash = NetAddr("127.0.0.1", ~dashPort);   // /rig comes to us
    ~trackInputs = [1, [0, 1]]; ~trackNames = ["one", "pair"];
    OSCdef(\dvRig, { |msg| rigs = rigs + 1; lastRig = msg }, '/rig');
    ok.("useDevice(nil) is accepted",      ~useDevice.(nil, nil, 0) == true);
    ok.("config now says system default",  ~audioDevice.isNil and: { ~inDevice.isNil });
    ok.("device change is marked unsaved", ~settingsDirty.any { |k| k == \audioDevice });
    waitFor.({ ~bootState == \ready }, 60);
    ok.("rig comes up",                    ~bootState == \ready);
    waitFor.({ ~tracks.notNil and: { ~tracks.size == 2 } and: { ~tracks.every { |t| t[\synth].notNil } } }, 20);
    ok.("tracks built from the layout",    ~tracks.size == 2 and: { ~tracks[1][\buf].numChannels == 2 });
    ok.("SuperDirt is up",                 ~dirt.notNil and: { ~dirt.orbits.size == ~dirtOrbits });
    ok.("exactly one Tidal responder",     dirtPlays.() == 1);
    ok.("dashboard was told (/rig)",       rigs > 0 and: { lastRig[1].asString == "ready" });

    "".postln; "--- SWITCH WHILE RUNNING: QUIT + BOOT ---".postln;
    ~tracks[0][\level] = 0.42;               // runtime state that should be rebuilt fresh
    ~useDevice.(nil, nil, 0, 4, 2);          // same device, explicit counts
    0.5.wait;
    ok.("goes through booting",            ~bootState == \booting or: { ~bootState == \ready });
    waitFor.({ ~bootState == \ready and: { s.serverRunning } }, 60);
    waitFor.({ ~tracks.size == 2 and: { ~tracks.every { |t| t[\synth].notNil } } }, 20);
    ok.("back up after the switch",        ~bootState == \ready and: { s.serverRunning });
    ok.("channel counts applied",          s.options.numInputBusChannels == 4);
    ok.("tracks rebuilt",                  ~tracks.size == 2 and: { ~tracks.every { |t| t[\buf].notNil } });
    ok.("still exactly one Tidal responder (old SuperDirt freed)", dirtPlays.() == 1);
    ok.("click scheduler alive",           ~clickTask.notNil and: { ~clickTask.isPlaying });

    "".postln;
    ("======== " ++ pass ++ " passed, " ++ fail ++ " failed ========").postln;
    0.5.wait;
    0.exit;
};
)
