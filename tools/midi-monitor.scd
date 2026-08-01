// ============================================================
//  LIVE LOOPER · tools/midi-monitor.scd
//  Find out what your controllers actually send, so you can map them.
//
//  Logs every note-on and CC with the DEVICE it came from — which matters as soon as
//  two controllers are plugged in, because note numbers collide across devices.
//
//    "D:/livelooper/tools/midi-monitor.scd".load;   // lists devices, starts logging
//    ~midiSummary.();                               // table of everything seen so far
//    ~midiMonitorClear.();                          // forget and start again
//    ~midiMonitorStop.();                           // stop logging
//
//  Workflow: start it, press each pad / turn each knob ONCE and deliberately, then run
//  ~midiSummary.() and read the numbers off the table.
//
//  NOTE: the looper pedals are still live while this runs. If a control you press is
//  already mapped (SPD notes 60/61/62 on ch 9) it will still fire. Set ~midiChan to
//  something unused first if that gets in the way.
// ============================================================

~midiSeen = ~midiSeen ? Dictionary.new;

// looper.scd defines this too, but only in recent versions — and if it is missing,
// `nil.(src)` returns nil silently rather than erroring, which is how the device column
// ended up reading "nil". Define it here so the tool stands on its own.
~midiDevName ?? {
    ~midiDevName = { |src|
        var ep = MIDIClient.sources !? { MIDIClient.sources.detect { |e| e.uid == src } };
        ep !? { ep.device ++ " / " ++ ep.name } ? ("uid " ++ src);
    };
};

~midiDevices = {
    "".postln;
    "=== MIDI sources ===".postln;
    if (MIDIClient.sources.isNil or: { MIDIClient.sources.isEmpty }) {
        "  none — is MIDIIn.connectAll run? (startup.scd does it)".postln;
    } {
        MIDIClient.sources.do { |e, i|
            ("  [" ++ i ++ "] " ++ e.device ++ " / " ++ e.name ++ "   (uid " ++ e.uid ++ ")").postln;
        };
    };
    "".postln;
};

~midiMonitorClear = { ~midiSeen = Dictionary.new; "midi monitor: cleared.".postln };

~midiMonitorStop = {
    [\mmNote, \mmCC].do { |k| MIDIdef.all[k] !? { |d| d.free } };
    "midi monitor stopped. (~midiSummary.() still works)".postln;
};

// One row per distinct control, so hammering a pad doesn't bury the table.
~midiNote = { |dev, type, chan, num, val|
    var key = (dev ++ "|" ++ type ++ "|" ++ chan ++ "|" ++ num).asSymbol;
    var row = ~midiSeen[key];
    row ?? {
        row = (dev: dev, type: type, chan: chan, num: num, count: 0, min: val, max: val);
        ~midiSeen[key] = row;
    };
    row[\count] = row[\count] + 1;
    row[\last]  = val;
    row[\min]   = min(row[\min], val);
    row[\max]   = max(row[\max], val);
};

~midiMonitorStart = {
    ~midiMonitorStop.();
    MIDIdef.noteOn(\mmNote, { |vel, num, chan, src|
        var dev = ~midiDevName.(src);
        ~midiNote.(dev, "note", chan, num, vel);
        ("note " ++ num.asString.padLeft(3) ++ "   ch " ++ chan.asString.padLeft(2)
            ++ "   vel " ++ vel.asString.padLeft(3) ++ "   [" ++ dev ++ "]").postln;
    }).fix;
    MIDIdef.cc(\mmCC, { |val, num, chan, src|
        var dev = ~midiDevName.(src);
        ~midiNote.(dev, "cc", chan, num, val);
        ("cc   " ++ num.asString.padLeft(3) ++ "   ch " ++ chan.asString.padLeft(2)
            ++ "   val " ++ val.asString.padLeft(3) ++ "   [" ++ dev ++ "]").postln;
    }).fix;
    "midi monitor running — press each pad / turn each knob, then ~midiSummary.()".postln;
};

~midiSummary = {
    var rows = ~midiSeen.values.asArray;
    "".postln;
    "======== WHAT I SAW ========".postln;
    if (rows.isEmpty) {
        "  nothing yet — press something.".postln;
    } {
        rows = rows.sort { |a, b|
            if (a[\dev] != b[\dev]) { a[\dev] < b[\dev] } {
                if (a[\type] != b[\type]) { a[\type] < b[\type] } { a[\num] < b[\num] }
            };
        };
        ("  " ++ "device".padRight(28) ++ "type  ch  num  hits   range").postln;
        ("  " ++ String.fill(60, $-)).postln;
        rows.do { |r|
            ("  " ++ r[\dev].asString.keep(27).padRight(28)
                ++ r[\type].padRight(6)
                ++ r[\chan].asString.padLeft(2) ++ "  "
                ++ r[\num].asString.padLeft(4) ++ "  "
                ++ r[\count].asString.padLeft(4) ++ "   "
                ++ r[\min] ++ ".." ++ r[\max]).postln;
        };
        "".postln;
        "  Pads/keys are 'note'; knobs are 'cc' with a range like 0..127.".postln;
        "  Put the numbers you want into config.scd (~mainPedal, ~clearPedal, ...).".postln;
    };
    "============================".postln;
    "".postln;
};

~midiDevices.();
~midiMonitorStart.();
