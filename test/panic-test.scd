// ============================================================
//  LIVE LOOPER · panic-test.scd
//  Regression test for Ctrl+. (CmdPeriod) survival.
//
//  Ctrl+. clears both clocks, frees every non-permanent responder, and frees every
//  node on the server. Everything the rig needs to keep working has to be registered
//  to come back. This test fires a real CmdPeriod.run and checks that it does.
//
//  Run it headless (does NOT need the ZOOM H8 — boots the system default device):
//    & "C:\Program Files\SuperCollider-3.14.1\sclang.exe" -D d:/livelooper/test/panic-test.scd
//
//  Expect: "26 passed, 0 failed". Re-run after touching looper/click/dashboard.
// ============================================================
(
var pass = 0, fail = 0, ok, self, synthBefore;

ok = { |label, cond|
    if (cond) { pass = pass + 1; ("  PASS  " ++ label).postln }
             { fail = fail + 1; ("  FAIL  " ++ label).postln };
};

// Dedicated server + port, so this is safe to run even while your rig is booted on the
// default 57110 — and so suites run back-to-back can't collide on a lingering scsynth.
s = Server(\llPanicTest, NetAddr("127.0.0.1", 57113));
Server.default = s;
s.options.device = nil;                 // system default — no ZOOM H8 needed
s.options.numInputBusChannels  = 12;    // match the real rig so SoundIn(8/9) is valid
s.options.numOutputBusChannels = 2;
s.options.memSize = 8192 * 16;

self = NetAddr("127.0.0.1", NetAddr.langPort);

s.waitForBoot({
    fork {
        1.0.wait;
        "D:/livelooper/config.scd".load;
        // Pin a known all-mono layout so this suite doesn't move when the rig's input
        // map does. Stereo tracks have their own suite.
        ~trackInputs = [9, 8, 5];
        ~trackNames  = ["a", "b", "c"];

        // looper.scd tracks tempo through ~dirt.receiveAction, so SuperDirt has to be
        // here. Build it WITHOUT loadSoundFiles — the sample library costs ~450 MB and
        // ~14 s and none of it is needed to test event handling. Listening on sclang's
        // own port avoids binding a second socket (and clashing with a live rig).
        ~dirtPort = NetAddr.langPort;
        ~dirt = SuperDirt(2, s);
        ~dirt.start(~dirtPort, [0, 0]);
        1.0.wait;

        ["looper.scd", "click.scd", "dashboard.scd"].do { |f|
            ("D:/livelooper/" ++ f).load;
        };
        // wait for the build fork rather than guessing a duration
        while { ~tracks.isNil or: { ~tracks.any { |x| x[\synth].isNil } } } { 0.2.wait };

        "".postln; "--- BEFORE PANIC ---".postln;
        ok.("track synths exist",        ~tracks.every { |t| t[\synth].notNil });
        ok.("click task playing",        ~clickTask.isPlaying);
        ok.("dashboard task playing",    ~dashRoutine.isPlaying);
        ok.("buildTracks on ServerTree", ServerTree.objects.at(s).includes(~buildTracks));
        ok.("clickTask on CmdPeriod",    CmdPeriod.objects.includes(~startClickTask));
        ok.("dashTask on CmdPeriod",     CmdPeriod.objects.includes(~startDashTask));

        // Buffers are pre-allocated mono at the ~minCps worst case, so recording never
        // allocates. (Full record-path coverage lives in test/looper-test.scd.)
        ok.("loop buffers are mono",     ~tracks.every { |t| t[\buf].numChannels == 1 });
        ok.("buffers sized for the longest loop", ~tracks.every { |t|
            t[\bufFrames] == (~loopFramesFor.(~minCps, ~maxLoopCycles) + ~xfadeFrames.()) });

        // NOTE: OSC floats are float32, so only use exactly-representable test values
        // (0.75, 0.25) — 0.4 round-trips to 0.4000000059604645 and would fail on ==.
        self.sendMsg('/dirt/play', "s", "bd", "cps", 0.75, "cycle", 40.0, "orbit", 0);
        0.3.wait;
        ok.("tempo tracking works",     ~cps == 0.75);
        ok.("receiveAction is installed", ~dirt.receiveAction.notNil);

        // The beat grid must be anchored to when an event SOUNDS, not when it arrives.
        // Anchored to arrival, recording opens early and leaves a hole at the punch-in
        // point. Send an event timestamped well ahead, then check SOON — the anchor has
        // to still be in the future, which only happens if it came from ev[\timeStamp].
        self.sendBundle(0.8, ['/dirt/play', "s", "bd", "cps", 0.75, "cycle", 41.0, "orbit", 0]);
        0.2.wait;
        ("        (anchor is " ++ ((~lastEventTime - Main.elapsedTime) * 1000).round(0.1)
            ++ " ms ahead of now)").postln;
        ok.("grid anchored to sounding time, not arrival",
            (~lastEventTime - Main.elapsedTime) > 0.3);

        // the whole point of the panic fix: this must be permanent, or CmdPeriod frees
        // it. Tempo tracking no longer needs it — receiveAction is a plain ivar on
        // ~dirt, and SuperDirt .fix'es the OSCFunc that calls it.
        ok.("cmdFocus is permanent",    OSCdef.all[\cmdFocus].permanent);

        // The MPK map is gone. Its responders were .fix'ed, which means they survive both
        // Ctrl+. AND a file reload — so loading looper.scd has to free them by key or a
        // long-running session would keep firing a mapping that no longer exists in the
        // source. Absence here is what proves the removal actually took effect.
        [\looperPads, \looperKnobs, \clickPedal, \midiPrint, \midiCcPrint].do { |k|
            ok.("no stale MIDIdef: " ++ k, MIDIdef.all[k].isNil);
        };

        // Simulate a track mid-performance: a recorded loop, playing, on a known downbeat.
        synthBefore = ~tracks[0][\synth].nodeID;
        ~tracks[0][\state]      = \playing;
        ~tracks[0][\startCycle] = 40;

        "".postln; "*** FIRING CmdPeriod.run (this is Ctrl+.) ***".postln;
        CmdPeriod.run;
        3.0.wait;                        // past the restore's next loop boundary

        "".postln; "--- AFTER PANIC ---".postln;
        ok.("track synth rebuilt (new node)",
            ~tracks[0][\synth].notNil and: { ~tracks[0][\synth].nodeID != synthBefore });
        ok.("loop buffer survived",      ~tracks[0][\buf].notNil);
        ok.("click task restarted",      ~clickTask.isPlaying);
        ok.("dashboard task restarted",  ~dashRoutine.isPlaying);

        self.sendMsg('/dirt/play', "s", "bd", "cps", 0.25, "cycle", 99.0, "orbit", 0);
        0.3.wait;
        ok.("tempo tracking SURVIVED", ~cps == 0.25);
        ok.("panic did not resurrect MIDI", MIDIdef.all[\looperPads].isNil);

        self.sendMsg('/cmd/focus', 1);
        0.3.wait;
        ok.("dashboard cmd responder SURVIVED", ~focus == 1);

        ok.("playing loop was restored",  ~tracks[0][\state] == \playing);
        ok.("idle track stayed idle",     ~tracks[1][\state] == \idle);

        "".postln;
        ("======== " ++ pass ++ " passed, " ++ fail ++ " failed ========").postln;
        0.5.wait;
        0.exit;
    };
});
)
