# Presets/

Every `.set` here is a **tune**: one complete set of inputs for one engine, in the
format MT5's Strategy Tester and chart dialog both load (`Inputs → Load`). Nothing
is hard-coded elsewhere — the values in these files are the values that ran.

Each file starts with a comment block that says what changed from the previous
version and *why*, with the numbers. The results themselves are published, run by
run, at **https://1kpips.com/en/presets** — including the runs that failed and the
reason each was rejected. A preset with no filed result has not been tested.

## Layout

| Folder | What is in it |
|---|---|
| `London/` | Per-pair presets for the 07:00–13:00 **broker server time** window (see below). The three marked `proven` on the site are running live at minimum lot. |
| `NewYork/`, `Tokyo/` | The same values with only the session changed. All rejected — the reason is in the file header and on the site. Kept so the negative result stays visible. |
| `Screening/` | `*_Multi_*` files have `InpTargetPair` empty and run unchanged across pairs (select the Expert first, then Load, then change only the Symbol). `*_opt_*` files are optimisation grids with the swept inputs flagged. |

## Naming

```
{Session}_{Strategy}_{Pair}_{TF}.set        one pair, one session
{Strategy}_Multi_{TF}.set                   any pair, screening
{Session}_{Strategy}_{Pair}_{TF}_opt_{what}.set   optimisation grid
```

`InpPresetVersion` inside the file is the tune's version; `InpEaVersion` is the engine
build it was tested on. Both are filed with every result.

## Session hours are broker server time

`InpStartHour` / `InpEndHour` with `InpUtcOffset` are applied to the **broker's server
clock**, which is what the Strategy Tester uses too — so what is tested is what runs.
On OANDA Japan the server is UTC+2 in winter and UTC+3 in summer. `16`–`22` with offset
`9` therefore means 07:00–13:00 server, i.e. 04:00–10:00 UTC in summer. Label your own
sessions the same way; a UTC label here would be wrong twice a year.

## Preset EA wrappers

Earlier versions of this repo shipped `Presets/{Session}/*.mq5` wrapper EAs. They were
retired in favour of `.set` files (one binary per engine, values in the file); the
wrappers no longer compiled against the current helpers and are not published.
