# Personal Trade Copier (MT5 → MT5)

A self-hosted copier in the style of TradersConnect, for your own accounts on one Windows VPS.

```
 MT5 #1 (master)              Common\Files\TradeCopier\           MT5 #2, #3 ... (followers)
 TC_Master.mq5  ── writes ──►  main.snap  (open trades) ◄── reads ── TC_Follower.mq5
                               master_main.json  status_<login>.json  ──► dashboard.py (browser)
                                                  control_<login>.txt ◄── Pause / Resume
```

Everything runs on the VPS. There is no cloud service, no API key and no monthly fee. Copy delay is typically under 100 ms.

## What it copies

- New trades, using one of four lot modes: fixed lot, master lot × multiplier, balance ratio or equity ratio. A max-lot cap applies in every mode.
- Closes and partial closes, proportionally.
- SL/TP changes, including trailing and breakeven moves made on the master.
- Symbol mapping between brokers (`XAUUSD=GOLD`), a per-symbol lot multiplier (`US30=DJ30*0.5`), and prefixes/suffixes such as `EURUSDm`.
- Reverse copying, which flips the direction and does not copy SL/TP.

Pending orders are not copied as orders. They are copied the moment they fill on the master.

## Safety rules built in

- **Stale master means freeze.** If the master snapshot is older than `StaleSec` (master EA stopped, terminal closed or disconnected), followers do nothing. They never close trades on old data.
- **Settle delay.** Both EAs wait `SettleSec` after start-up or a reconnect, so a not-yet-loaded empty position list can't trigger "close everything".
- **Half-written files are ignored.** Each snapshot ends with a line count, and followers only act on a complete file.
- **Master account lock.** If the master terminal switches to a different login, followers halt. Set `ExpectedMasterLogin` to pin it.
- **Old trades aren't copied.** Trades already open when a follower starts are ignored unless `CopyExistingOnStart=true`, and trades older than `MaxOpenDelaySec` are skipped. This stops a late fill at a bad price after downtime.
- **Retries and backoff.** A failed open is retried every 2 s and abandoned after `MaxOpenAttempts`. Failed closes and modifies are retried every 3–5 s. Every failure and its reason are logged.

## Setup on the VPS

### 1. One MT5 installation per account
One MT5 terminal can only be logged into one account at a time, so install MT5 once per account in separate folders, for example `C:\MT5\Master`, `C:\MT5\Follow1` and `C:\MT5\Follow2`. Most brokers' installers let you choose the folder under *Settings*. Log each terminal into its account. All of them must run under the **same Windows user**, because they share `%APPDATA%\MetaQuotes\Terminal\Common\Files`.

Use **hedging** accounts. The follower logs a warning on netting accounts.

### 2. Install the EAs
In **each** terminal: *File → Open Data Folder → MQL5 → Experts*. Copy `TC_Master.mq5` and `TC_Follower.mq5` there, then open MetaEditor (F4), open each file and press **Compile** (F7). It should report 0 errors.

### 3. Start the master
In the master terminal, open any chart and drag **TC_Master** onto it. Keep `Channel = main`. The master doesn't trade, so Algo Trading is not needed there.

### 4. Start each follower
In each follower terminal:
1. Turn on the **Algo Trading** button in the toolbar.
2. Drag **TC_Follower** onto any chart. On the *Common* tab, tick *Allow Algo Trading*.
3. Set the inputs. Typical starting values:
   - `ExpectedMasterLogin` = your master account number
   - `LotMode` = *Scale by balance ratio*, `Multiplier` = 1
   - `MaxLot` = a cap you're comfortable with
   - `SymbolMap` / `SymbolSuffix` if the follower broker names symbols differently. Check the follower's Market Watch.
4. Use a **different `CopierMagic`** only if you run two followers inside the *same* terminal (rare).

Use only one EA per chart. Any symbol works, because the EA handles every symbol.

### 5. Dashboard (optional)
Install Python 3 from python.org and tick "Add to PATH". Then double-click `dashboard\start_dashboard.bat`, or run:

```
python dashboard\dashboard.py
```

Open http://127.0.0.1:8080 in a browser *on the VPS*. It shows the master, every follower and its state, each master trade with its copies underneath (or why it wasn't copied), P/L, and a live activity log. Use **Pause** on a follower to stop new copies. Closes and SL/TP changes still mirror while paused, so you're never left holding orphan trades.

The dashboard only listens on 127.0.0.1, so it isn't reachable from the internet. If you want to see it from your laptop, use an SSH tunnel or RDP rather than opening the port.

## Test it first
1. Run everything on **demo** accounts.
2. On the master, open 0.10 lots on EURUSD with an SL and a TP. The follower should copy it within a second, and the Experts tab shows `[TC] Copied master #…`.
3. Move the SL, close half, then close the rest. Check that each step mirrors.
4. Close the master terminal. The follower state should go to `MASTER OFFLINE` and nothing should be closed.
5. Only then switch the follower terminals to live accounts.

## Follower inputs

| Input | Default | Meaning |
|---|---|---|
| Channel | main | Must match the master |
| ExpectedMasterLogin | 0 | Halt if the master login differs (0 = lock to the first seen) |
| StaleSec | 10 | Freeze when the master heartbeat is older than this |
| LotMode | Multiplier | Fixed / Multiplier / Balance ratio / Equity ratio |
| FixedLot | 0.01 | Lot used in Fixed mode |
| Multiplier | 1.0 | Applied in the non-fixed modes |
| MaxLot | 5.0 | Hard cap per trade (0 = none) |
| UseMinLotIfTooSmall | true | Round tiny results up to the broker minimum instead of skipping |
| CopySLTP | true | Copy SL/TP and keep them in sync |
| CopyCloses / CopyPartialCloses | true | Mirror full and partial closes |
| Reverse | false | Flip buy/sell |
| CopyExistingOnStart | false | Also copy trades already open when the EA starts |
| MaxOpenDelaySec | 30 | Skip master trades older than this |
| OnlySymbols | (empty) | Copy only these master symbols, e.g. `XAUUSD,EURUSD` |
| SymbolMap | (empty) | `MASTER=FOLLOWER[*lotmult]`, separated by `;` |
| StripMasterSuffix | (empty) | e.g. `.raw` turns master `EURUSD.raw` into `EURUSD` |
| SymbolPrefix / SymbolSuffix | (empty) | Added to the symbol on the follower |
| SlippagePoints | 30 | Max deviation for market orders |

## Notes
- **Contract sizes differ between brokers.** Gold is often 100 oz on one broker and 1 oz or 10 oz on another, and indices vary too. Check *Symbol → Specification* on both accounts and use a `*mult` in `SymbolMap` where they differ.
- **Prop firms:** copying between your own accounts is usually allowed, but some firms restrict copying into or out of funded accounts, or ban identical trades across firms. Check your firm's rules.
- **Logs:** each follower keeps its last 40 messages for the dashboard. Everything is also in the terminal's *Experts* tab.
