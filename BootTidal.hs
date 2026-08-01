-- ============================================================
--  LIVE LOOPER · BootTidal.hs   (Tidal 1.10.x)
--  Copied from the tidal package's own shipped boot file so it matches
--  the installed version exactly. `mkTidal` uses the default
--  superdirtTarget (127.0.0.1:57120) — i.e. our running SuperDirt.
--
--  The VS Code extension is pointed here via .vscode/settings.json
--  (tidalcycles.bootTidalPath). This is required because
--  `cabal install tidal --lib` does NOT register tidal in ghc-pkg, so
--  the extension's `ghc-pkg field tidal data-dir` auto-lookup fails.
-- ============================================================

:set -fno-warn-orphans -Wno-type-defaults -XMultiParamTypeClasses -XOverloadedStrings
:set prompt ""

-- Import all the boot functions and aliases (d1..d16, hush, setcps, ...).
import Sound.Tidal.Boot

default (Rational, Integer, Double, Pattern String)

-- Create a Tidal Stream. oLatency default is 0.2 (200ms) which makes patterns lag
-- behind your live guitar and the SC click; 0.1 tightens the feel. Go lower (0.06,
-- 0.05) for even tighter timing, but back off if you hear dropouts or "late message"
-- warnings in the Tidal terminal.
tidalInst <- mkTidalWith [(superdirtTarget { oLatency = 0.1 }, [superdirtShape])] defaultConfig
-- default was: tidalInst <- mkTidal

-- This orphan instance makes the boot aliases work. Must come after tidalInst.
instance Tidally where tidal = tidalInst

-- `enableLink` / `disableLink` toggle Ableton Link sync (built into Tidal 1.10).
-- Uncomment to enable on startup:
-- enableLink

-- Add your own aliases below, e.g.:
-- fastsquizzed pat = fast 2 $ pat # squiz 1.5

:set prompt "tidal> "
:set prompt-cont ""
