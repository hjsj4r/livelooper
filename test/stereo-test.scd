// ============================================================
//  LIVE LOOPER · stereo-test.scd
//  A track fed by TWO inputs (a stereo mic) must record and play back in stereo, while
//  mono tracks alongside it keep working. Checks the buffer width, the SynthDef chosen,
//  and — as audio — that left and right stay separate rather than being summed.
//
//  Run it headless (no ZOOM H8 needed):
//    & "C:\Program Files\SuperCollider-3.14.1\sclang.exe" -D d:/livelooper/test/stereo-test.scd
//
//  Expect: "12 passed, 0 failed".
// ============================================================
(
var pass = 0, fail = 0, ok, st, mo;

ok = { |label, cond|
    if (cond) { pass = pass + 1; ("  PASS  " ++ label).postln }
             { fail = fail + 1; ("  FAIL  " ++ label).postln };
};

s = Server(\llStereoTest, NetAddr("127.0.0.1", 57145));
Server.default = s;
s.options.device = nil;
s.options.numInputBusChannels  = 12;
s.options.numOutputBusChannels = 2;
s.options.memSize = 8192 * 16;

s.waitForBoot({
    fork {
        1.0.wait;
        "D:/livelooper/config.scd".load;
        // one stereo track (a pair, deliberately NON-adjacent) plus two mono ones.
        // Names must be overridden too — config's list is sized for the real rig.
        ~trackInputs = [[4, 7], 5, 9];
        ~trackNames  = ["pair", "monoA", "monoB"];
        ~dirtPort = NetAddr.langPort;
        ~dirt = SuperDirt(2, s);
        ~dirt.start(~dirtPort, [0, 0]);
        1.0.wait;
        "D:/livelooper/looper.scd".load;
        while { ~tracks.isNil or: { ~tracks.any { |x| x[\synth].isNil } } } { 0.2.wait };

        st = ~tracks[0];      // stereo
        mo = ~tracks[1];      // mono

        "".postln; "--- TRACK SHAPES ---".postln;
        ok.("stereo track has 2 inputs",  st[\inputs] == [4, 7]);
        ok.("mono track has 1 input",     mo[\inputs] == [5]);
        ok.("stereo buffer is 2 channels", st[\buf].numChannels == 2);
        ok.("mono buffer is 1 channel",    mo[\buf].numChannels == 1);
        ok.("stereo label reads as a pair", ~inLabel.(st) == "4+7");
        ok.("mono label is a single index", ~inLabel.(mo) == "5");
        ok.("tracks carry their names",     st[\name] == "pair" and: { mo[\name] == "monoA" });
        ok.("both synths exist",           st[\synth].notNil and: { mo[\synth].notNil });

        "".postln; "--- STEREO IS NOT SUMMED ---".postln;
        // Write DIFFERENT constants into L and R, then meter the output bus. If the
        // stereo path were collapsing to mono, both sides would read the same.
        st[\loopFrames] = ~loopFramesFor.(2.0);
        SynthDef(\stMeter, {
            SendReply.kr(Impulse.kr(10), '/stMeter', Amplitude.kr(In.ar(0, 2), 0.01, 0.05));
        }).add;
        s.sync;
        OSCFunc({ |msg| ~sL = msg[3]; ~sR = msg[4] }, '/stMeter');
        // interleaved L,R,L,R... — L = 0.6, R = 0.2
        st[\buf].loadCollection(
            Array.fill(st[\loopFrames] * 2, { |i| if (i.even) { 0.6 } { 0.2 } }), 0);
        s.sync;
        st[\synth].set(\recRun, 0, \recLevel, 0, \preLevel, 1,
            \playing, 1, \monLevel, 0, \level, 1.0);
        ~meter = Synth(\stMeter, addAction: \addToTail);
        1.5.wait;
        ("        (L = " ++ ~sL.round(0.001) ++ ", R = " ++ ~sR.round(0.001) ++ ")").postln;
        ok.("left carries its own signal",  (~sL - 0.6).abs < 0.05);
        ok.("right carries its own signal", (~sR - 0.2).abs < 0.05);
        ok.("channels are NOT summed",      (~sL - ~sR).abs > 0.2);
        st[\synth].set(\playing, 0);
        1.0.wait;
        ok.("playing=0 silences it",        ~sL < 0.02);
        ~meter.free;

        "".postln;
        ("======== " ++ pass ++ " passed, " ++ fail ++ " failed ========").postln;
        0.5.wait;
        0.exit;
    };
});
)
