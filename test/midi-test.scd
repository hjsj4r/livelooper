// ============================================================
//  LIVE LOOPER · midi-test.scd
//  The MPK mini control surface: one pad per track, no focus mode.
//  Also checks what must NOT respond — the MPK's keyboard and the SPD-SX.
//
//  Run it headless (no MIDI hardware needed — MIDI input is simulated):
//    & "C:\Program Files\SuperCollider-3.14.1\sclang.exe" -D d:/livelooper/test/midi-test.scd
//
//  Expect: "17 passed, 0 failed".
// ============================================================
(
var pass = 0, fail = 0, ok, hit;

ok = { |label, cond|
    if (cond) { pass = pass + 1; ("  PASS  " ++ label).postln }
             { fail = fail + 1; ("  FAIL  " ++ label).postln };
};
// fake a controller press: uid is arbitrary, the handlers key off channel + number
hit = { |chan, num, vel = 127| MIDIIn.doNoteOnAction(999, chan, num, vel) };

// 57140, deliberately clear of the 5712x range: when another SuperCollider already holds
// the default lang port 57120, this sclang falls back to 57121/57122/... and a server
// addressed there would be talking to the interpreter itself.
s = Server(\llMidiTest, NetAddr("127.0.0.1", 57140));
Server.default = s;
s.options.device = nil;
s.options.numInputBusChannels  = 12;
s.options.numOutputBusChannels = 2;

s.waitForBoot({
    fork {
        1.0.wait;
        "D:/livelooper/config.scd".load;
        ~dirtPort = NetAddr.langPort;
        ~dirt = SuperDirt(2, s);
        ~dirt.start(~dirtPort, [0, 0]);
        1.0.wait;
        ["looper.scd", "click.scd"].do { |f| ("D:/livelooper/" ++ f).load };
        while { ~tracks.isNil or: { ~tracks.any { |x| x[\synth].isNil } } } { 0.2.wait };
        ~cps = 4.0; ~lastCycle = 0; ~lastEventTime = Main.elapsedTime;   // 4 cycles = 1 s

        "".postln; "--- MAP ---".postln;
        ok.("channel is the MPK's",   ~midiChan == 0);
        ok.("3 main pads",            ~padMain.size == ~tracks.size);
        ok.("3 clear pads",           ~padClear.size == ~tracks.size);
        ok.("3 fader knobs",          ~knobFader.size == ~tracks.size);

        "".postln; "--- PADS DRIVE THEIR OWN TRACK ---".postln;
        hit.(0, ~padMain[1]);                       // pad 37 -> track 1 only
        0.3.wait;
        ok.("main pad armed track 1",  ~tracks[1][\state] == \recording);
        ok.("track 0 untouched",       ~tracks[0][\state] == \idle);
        ok.("track 2 untouched",       ~tracks[2][\state] == \idle);

        hit.(0, ~padMain[2]);                       // pad 38 -> track 2
        0.3.wait;
        ok.("main pad armed track 2",  ~tracks[2][\state] == \recording);

        hit.(0, ~padClear[1]);                      // pad 33 -> clear track 1
        0.3.wait;
        ok.("clear pad cleared track 1", ~tracks[1][\state] == \idle);
        ok.("clear left track 2 alone",  ~tracks[2][\state] == \recording);
        hit.(0, ~padClear[2]);
        0.3.wait;

        "".postln; "--- KNOBS ---".postln;
        MIDIIn.doControlAction(999, 0, ~knobFader[0], 0);
        0.2.wait;
        ok.("knob 0 -> fader 0.0",     ~tracks[0][\level] == 0.0);
        MIDIIn.doControlAction(999, 0, ~knobFader[2], 127);
        0.2.wait;
        ok.("knob 2 -> fader 1.0",     ~tracks[2][\level] == 1.0);
        MIDIIn.doControlAction(999, 0, ~knobFader[1], 64);
        0.2.wait;
        ok.("knob 1 -> mid fader",     (~tracks[1][\level] - 0.504).abs < 0.01);
        ok.("knobs are independent",   ~tracks[0][\level] == 0.0);

        "".postln; "--- WHAT MUST NOT RESPOND ---".postln;
        // the MPK keyboard shares channel 0; the retired map used notes 60/61, so
        // playing those keys used to start and clear recordings
        hit.(0, 60); hit.(0, 61); hit.(0, 62);
        0.3.wait;
        ok.("keyboard notes do nothing", ~tracks.every { |t| t[\state] == \idle });
        // the SPD-SX is on channel 9 and must stay a pure instrument
        hit.(9, ~padMain[0]); hit.(9, 60);
        0.3.wait;
        ok.("SPD (ch 9) does nothing",  ~tracks.every { |t| t[\state] == \idle });
        ok.("old focus handler is gone", MIDIdef.all[\looperPedal].isNil);

        "".postln;
        ("======== " ++ pass ++ " passed, " ++ fail ++ " failed ========").postln;
        0.5.wait;
        0.exit;
    };
});
)
