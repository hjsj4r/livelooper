// ============================================================
//  LIVE LOOPER · midi-test.scd
//  The MPK mini control surface: three fixed pads acting on the SELECTED track.
//  Also checks what must NOT respond — the MPK's keyboard and the SPD-SX.
//
//  Run it headless (no MIDI hardware needed — MIDI input is simulated):
//    & "C:\Program Files\SuperCollider-3.14.1\sclang.exe" -D d:/livelooper/test/midi-test.scd
//
//  Expect: "38 passed, 0 failed".
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
        ok.("record pad is a number", ~padRecord.isNumber);
        ok.("overdub pad is a number", ~padOverdub.isNumber);
        ok.("clear pad is a number",  ~padClear.isNumber);
        ok.("rec/dub/clr are distinct",
            [~padRecord, ~padOverdub, ~padClear].asSet.size == 3);

        "".postln; "--- PADS ACT ON THE SELECTED TRACK ---".postln;
        ~focus = 1;
        hit.(0, ~padRecord);
        0.3.wait;
        ok.("record hit the selected track", ~tracks[1][\state] == \recording);
        ok.("track 0 untouched",             ~tracks[0][\state] == \idle);
        ok.("track 2 untouched",             ~tracks[2][\state] == \idle);

        // move the selection; the same pad must now drive a different track
        ~focus = 2;
        hit.(0, ~padRecord);
        0.3.wait;
        ok.("selection redirects the pad",   ~tracks[2][\state] == \recording);
        ok.("track 1 still recording",       ~tracks[1][\state] == \recording);

        hit.(0, ~padClear);
        0.3.wait;
        ok.("clear hit the selected track",  ~tracks[2][\state] == \idle);
        ok.("clear left track 1 alone",      ~tracks[1][\state] == \recording);
        ~focus = 1; hit.(0, ~padClear);
        0.3.wait;
        ~focus = 0;

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

        "".postln; "--- NAVIGATION (DualSense stick / d-pad) ---".postln;
        // stepping onto a track selects it outright — no separate commit
        ~focus = 0;
        ~navMove.(1);
        ok.("nav selects as it steps",   ~focus == 1);
        ~navMove.(1); ~navMove.(1);
        ok.("nav keeps stepping",        ~focus == 3);
        // The list runs past the tracks onto the two mixer levels, so the stick can
        // reach every fader without a mode.
        ok.("list is tracks + 2 mixer items", ~navSize.() == (~tracks.size + 2));
        ~focus = ~tracks.size - 1;
        ~navMove.(1);
        ok.("steps off the tracks onto tidal", ~focus == ~tracks.size);
        ok.("...which is not a track",         ~navIsTrack.().not);
        ok.("and is named",                    ~navName.() == "tidal level");
        ~navMove.(1);
        ok.("then onto click",                 ~focus == (~tracks.size + 1));
        // wrapping, so running off the end doesn't feel broken with no scrollbar
        ~navMove.(1);
        ok.("wraps forward to the first track", ~focus == 0);
        ~navMove.(-1);
        ok.("wraps backward onto click",        ~focus == (~navSize.() - 1));
        ~navFocus.(2);
        ok.("navFocus jumps directly",   ~focus == 2);
        ok.("...and that IS a track",    ~navIsTrack.());

        "".postln; "--- STICK ADJUSTS THE SELECTED LEVEL ---".postln;
        ~navFocus.(1);
        ~trackLevel.(~tracks[1], 0.5);
        // capture rather than assume — the knob section above already moved track 0
        ~other = ~tracks[0][\level];
        ~navAdjust.(0.2);
        ok.("adjusts the selected track", (~tracks[1][\level] - 0.7).abs < 0.001);
        ok.("leaves other tracks alone",  ~tracks[0][\level] == ~other);
        ~navAdjust.(9);
        ok.("clamps at 1",               ~tracks[1][\level] == 1.0);
        ~navAdjust.(-9);
        ok.("clamps at 0",               ~tracks[1][\level] == 0.0);
        ~trackLevel.(~tracks[1], 1.0);
        // and the mixer items respond to the same control
        ~navFocus.(~tracks.size);
        ~dirtLevel = 0.5; ~navAdjust.(0.25);
        ok.("adjusts the tidal level",   (~dirtLevel - 0.75).abs < 0.001);
        ~navFocus.(~tracks.size + 1);
        ~clickAmp = 0.5; ~navAdjust.(-0.25);
        ok.("adjusts the click level",   (~clickAmp - 0.25).abs < 0.001);
        ~clickAmp = 0.5; ~dirtLevel = 1.0;
        // a transport button on a mixer item must do NOTHING
        ~navFocus.(~tracks.size);
        hit.(0, ~padRecord);
        0.3.wait;
        ok.("record on a mixer item is ignored",
            ~tracks.every { |x| x[\state] == \idle });
        ~navFocus.(2);
        // the transport buttons act on whatever navigation landed on
        hit.(0, ~padRecord);
        0.3.wait;
        ok.("buttons follow the selection",
            ~tracks[2][\state] == \recording and: { ~tracks[5][\state] == \idle });
        hit.(0, ~padClear);
        0.3.wait;
        ~focus = 0;

        "".postln; "--- WHAT MUST NOT RESPOND ---".postln;
        // the MPK keyboard shares channel 0; the retired map used notes 60/61, so
        // playing those keys used to start and clear recordings
        hit.(0, 60); hit.(0, 61); hit.(0, 62);
        0.3.wait;
        ok.("keyboard notes do nothing", ~tracks.every { |t| t[\state] == \idle });
        // the SPD-SX is on channel 9 and must stay a pure instrument
        hit.(9, ~padRecord); hit.(9, 60);
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
