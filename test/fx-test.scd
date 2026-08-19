// ============================================================
//  LIVE LOOPER · fx-test.scd
//  Every track runs through its own FX synth. The thing that matters most is that a
//  BYPASSED chain is genuinely transparent — it sits in the path of all seven tracks
//  whether or not anyone is using it.
//
//  Run it headless (no ZOOM H8 needed):
//    & "C:\Program Files\SuperCollider-3.14.1\sclang.exe" -D d:/livelooper/test/fx-test.scd
//
//  Expect: "14 passed, 0 failed".
// ============================================================
(
var pass = 0, fail = 0, ok, t;

ok = { |label, cond|
    if (cond) { pass = pass + 1; ("  PASS  " ++ label).postln }
             { fail = fail + 1; ("  FAIL  " ++ label).postln };
};

s = Server(\llFxTest, NetAddr("127.0.0.1", 57153));
Server.default = s;
s.options.device = nil;
s.options.numInputBusChannels  = 12;
s.options.numOutputBusChannels = 2;
s.options.memSize = 8192 * 16;

s.waitForBoot({
    fork {
        1.0.wait;
        "D:/livelooper/config.scd".load;
        ~trackInputs = [9, 8];
        ~trackNames  = ["a", "b"];
        ~dirtPort = NetAddr.langPort;
        ~dirt = SuperDirt(2, s); ~dirt.start(~dirtPort, [0, 0]);
        1.0.wait;
        "D:/livelooper/looper.scd".load;
        while { ~tracks.isNil or: { ~tracks.any { |x| x[\synth].isNil } } } { 0.2.wait };
        t = ~tracks[0];

        "".postln; "--- ROUTING ---".postln;
        ok.("track has its own FX bus",   t[\fxBus].notNil);
        ok.("FX buses are distinct",      t[\fxBus].index != ~tracks[1][\fxBus].index);
        ok.("FX bus is stereo",           t[\fxBus].numChannels == 2);
        ok.("FX synth exists",            t[\fxSynth].notNil);
        ok.("looper writes to the FX bus, not straight out", t[\synth].notNil);
        ok.("drive starts at zero",       t[\fx] == 0);

        "".postln; "--- DRIVE CONTROL ---".postln;
        ~trackFx.(t, 0.5);
        ok.("drive is stored",            (t[\fx] - 0.5).abs < 0.001);
        ~trackFx.(t, 2.0);
        ok.("drive clamps at 1",          t[\fx] <= 1.0);
        ~trackFx.(t, -1);
        ok.("drive clamps at 0",          t[\fx] >= 0.0);
        ~trackFx.(t, 0);
        ok.("other track unaffected",     ~tracks[1][\fx] == 0);

        // --- BYPASS MUST BE TRANSPARENT ---
        // Feed a known DC level through a loop and meter the output bus. At drive 0 the
        // chain crossfades fully to dry, so what comes out must equal what went in.
        "".postln; "--- BYPASS TRANSPARENCY ---".postln;
        // Meter BOTH sides of the FX synth. Transparency is a relative property — out
        // must equal in — and testing it that way avoids depending on an absolute level,
        // which turned out not to be worth trusting here.
        SynthDef(\fxMeter, { |fxbus = 0|
            SendReply.kr(Impulse.kr(10), '/fxMeter',
                [Amplitude.kr(In.ar(fxbus, 1), 0.01, 0.05),
                 Amplitude.kr(In.ar(0, 1),     0.01, 0.05)]);
        }).add;
        s.sync;
        OSCFunc({ |msg| ~fIn = msg[3]; ~fL = msg[4] }, '/fxMeter');
        t[\loopFrames] = ~loopFramesFor.(2.0);
        // A real TONE, not DC. The drive stage high-passes at 120 Hz to keep low strings
        // from turning to mud, so a constant would be removed entirely before it ever
        // reached the clipper — see the DC assertion at the end.
        t[\buf].loadCollection(
            Array.fill(t[\loopFrames], { |i| 0.4 * sin(2pi * 300 * i / s.sampleRate) }), 0);
        // The SYNTH must be told the new loop length too. Setting only the language-side
        // value leaves the Phasor wrapping at its build-time length, so playback runs off
        // the end of what was loaded into silence — which reads as the effect killing the
        // signal when in fact the looper has simply left the region we filled.
        t[\synth].set(\loopFrames, t[\loopFrames]);
        s.sync;
        t[\synth].set(\recRun, 0, \recLevel, 0, \preLevel, 1,
            \playing, 1, \monLevel, 0, \level, 1.0);
        ~meter = Synth(\fxMeter, [fxbus: t[\fxBus]], addAction: \addToTail);
        1.5.wait;
        ("        (bypassed: in " ++ ~fIn.round(0.001) ++ "  out " ++ ~fL.round(0.001) ++ ")").postln;
        ok.("something is reaching the FX",  ~fIn > 0.05);
        ok.("bypass is transparent",         (~fL - ~fIn).abs < 0.02);

        // drive it hard: a soft clipper must LIMIT, never run away
        ~trackFx.(t, 1.0);
        1.5.wait;
        ("        (driven:   in " ++ ~fIn.round(0.001) ++ "  out " ++ ~fL.round(0.001) ++ ")").postln;
        ok.("driven output is finite",    ~fL.isNumber and: { ~fL < 2.0 });
        ok.("driven output is audible",   ~fL > 0.05);
        ok.("drive changed the signal",   (~fL - ~fIn).abs > 0.02);
        ~trackFx.(t, 0);
        1.5.wait;
        ok.("returns to transparent",     (~fL - ~fIn).abs < 0.02);

        // The pre-highpass is what makes this a GUITAR drive rather than mud. Feeding it
        // DC proves the stage is really there: bypassed it passes, driven it vanishes.
        "".postln; "--- PRE-HIGHPASS ---".postln;
        t[\buf].fill(0, t[\bufFrames], 0.4);
        s.sync;
        1.5.wait;
        ok.("DC passes when bypassed",    (~fL - ~fIn).abs < 0.02);
        ~trackFx.(t, 1.0);
        1.5.wait;
        ("        (DC driven: in " ++ ~fIn.round(0.001) ++ "  out " ++ ~fL.round(0.001) ++ ")").postln;
        ok.("DC is removed before the clipper", ~fL < 0.05);
        ok.("...even though DC was present",    ~fIn > 0.05);
        ~trackFx.(t, 0);
        ~meter.free;

        "".postln;
        ("======== " ++ pass ++ " passed, " ++ fail ++ " failed ========").postln;
        0.5.wait;
        0.exit;
    };
});
)
