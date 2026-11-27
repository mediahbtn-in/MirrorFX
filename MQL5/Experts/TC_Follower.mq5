//+------------------------------------------------------------------+
//|                                                  TC_Follower.mq5 |
//|  Trade Copier - FOLLOWER                                         |
//|  Reads the snapshot published by TC_Master and mirrors it on     |
//|  this account: opens, closes, partial closes and SL/TP changes.  |
//+------------------------------------------------------------------+
#property copyright "Personal use"
#property version   "1.00"
#property description "Trade Copier FOLLOWER - mirrors positions published by TC_Master."

#include <Trade\Trade.mqh>

enum ENUM_TC_LOT_MODE
  {
   TC_LOT_FIXED      = 0, // Fixed lot
   TC_LOT_MULTIPLIER = 1, // Master lot x Multiplier
   TC_LOT_BALANCE    = 2, // Scale by balance ratio x Multiplier
   TC_LOT_EQUITY     = 3  // Scale by equity ratio x Multiplier
  };

input group "Connection"
input string Channel             = "main"; // Channel name (same as on TC_Master)
input long   ExpectedMasterLogin = 0;      // Master account number (0 = accept first seen)
input int    StaleSec            = 10;     // Freeze if master snapshot is older than this
input int    TimerMs             = 25;     // Sync interval in milliseconds
input int    SettleSec           = 3;      // Wait after start/reconnect before acting

input group "Lot sizing"
input ENUM_TC_LOT_MODE LotMode   = TC_LOT_MULTIPLIER; // Lot mode
input double FixedLot            = 0.01;   // Lot for Fixed mode
input double Multiplier          = 1.0;    // Multiplier for the other modes
input double MaxLot              = 5.0;    // Never open more than this (0 = no cap)
input bool   UseMinLotIfTooSmall = true;   // Use broker min lot if the result is too small

input group "What to copy"
input bool   CopySLTP            = true;   // Copy and keep SL/TP in sync
input bool   CopyCloses          = true;   // Close when master closes
input bool   CopyPartialCloses   = true;   // Mirror partial closes proportionally
input bool   Reverse             = false;  // Reverse direction (SL/TP not copied)
input bool   CopyExistingOnStart = false;  // Copy trades already open when EA starts
input int    MaxOpenDelaySec     = 30;     // Skip trades older than this (0 = off)
input string OnlySymbols         = "";     // Copy only these master symbols, comma separated

input group "Symbols"
input string SymbolMap           = "";     // e.g. XAUUSD=GOLD;US30=DJ30*0.5
input string StripMasterSuffix   = "";     // Remove this suffix from master symbols, e.g. .raw
input string SymbolPrefix        = "";     // Add before symbol on this account
input string SymbolSuffix        = "";     // Add after symbol on this account, e.g. m

input group "Execution"
input long   CopierMagic         = 770077; // Magic number for copied trades
input int    SlippagePoints      = 30;     // Max slippage in points
input int    MaxOpenAttempts     = 5;      // Give up on a trade after this many failures

#define TC_DIR "TradeCopier"

//--- master snapshot
struct MasterPos
  {
   ulong             ticket;
   string            symbol;
   int               type;
   double            volume;
   double            sl;
   double            tp;
   long              openGmt;
  };
MasterPos g_m[];
int    g_mCount   = 0;
long   g_hdrSeq   = 0;
long   g_hdrTime  = 0;
long   g_hdrLogin = 0;
double g_mBalance = 0;
double g_mEquity  = 0;

//--- bookkeeping
struct Attempt { ulong tk; int count; ulong last; };
struct Backoff { ulong tk; ulong until; };
struct Recent  { ulong tk; ulong at; };
Attempt g_att[];
Backoff g_bo[];
Recent  g_recent[];
ulong   g_skip[];

string g_mapFrom[];
string g_mapTo[];
double g_mapMult[];
string g_only[];
string g_log[];

string g_snapFile, g_statusFile, g_controlFile;
string g_state       = "STARTING";
bool   g_initialized = false;
bool   g_halted      = false;
bool   g_paused      = false;
long   g_firstLogin  = 0;
ulong  g_lastStatus  = 0;
ulong  g_lastControl = 0;
ulong  g_readyAt     = 0;
bool   g_wasConnected = false;

CTrade trade;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(StringLen(Channel) == 0)
     {
      Alert("TC_Follower: Channel must not be empty");
      return INIT_PARAMETERS_INCORRECT;
     }
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   g_snapFile    = TC_DIR + "\\" + Channel + ".snap";
   g_statusFile  = TC_DIR + "\\status_" + IntegerToString(login) + ".json";
   g_controlFile = TC_DIR + "\\control_" + IntegerToString(login) + ".txt";
   FolderCreate(TC_DIR, FILE_COMMON);

   ParseSymbolMap();
   ParseList(OnlySymbols, g_only);

   trade.SetExpertMagicNumber(CopierMagic);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetAsyncMode(false);

   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Log("WARNING: this account is not a hedging account. The copier is built for hedging accounts.");

   g_readyAt = GetTickCount64() + (ulong)MathMax(0, SettleSec) * 1000;
   g_wasConnected = (bool)TerminalInfoInteger(TERMINAL_CONNECTED);
   ReadControl();

   if(!EventSetMillisecondTimer(MathMax(10, TimerMs)))
     {
      Alert("TC_Follower: could not start timer");
      return INIT_FAILED;
     }
   Log("Started. Channel '" + Channel + "', account " + IntegerToString(login));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   g_state = "STOPPED";
   WriteStatus();
  }

void OnTick() {}

void OnTimer()
  {
   ulong now = GetTickCount64();
   if(now - g_lastControl >= 500)
     {
      g_lastControl = now;
      ReadControl();
     }
   Sync();
   if(now - g_lastStatus >= 1000)
     {
      g_lastStatus = now;
      WriteStatus();
     }
  }

//+------------------------------------------------------------------+
//| Logging (Experts tab + last 40 lines for the dashboard)          |
//+------------------------------------------------------------------+
void Log(const string msg)
  {
   Print("[TC] ", msg);
   string line = TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS) + "  " + msg;
   int n = ArraySize(g_log);
   if(n >= 40)
     {
      for(int i = 1; i < n; i++)
         g_log[i - 1] = g_log[i];
      g_log[n - 1] = line;
     }
   else
     {
      ArrayResize(g_log, n + 1);
      g_log[n] = line;
     }
  }

void Halt(const string why)
  {
   if(!g_halted)
     {
      g_halted = true;
      Log("HALTED: " + why + " Re-attach the EA after fixing this.");
      Alert("TC_Follower halted: ", why);
     }
   g_state = "HALTED";
  }

//+------------------------------------------------------------------+
//| Small list helpers                                               |
//+------------------------------------------------------------------+
string Trim(string s)
  {
   StringTrimLeft(s);
   StringTrimRight(s);
   return s;
  }

void ParseList(const string src, string &out[])
  {
   ArrayResize(out, 0);
   string parts[];
   int n = StringSplit(src, ',', parts);
   for(int i = 0; i < n; i++)
     {
      string s = Trim(parts[i]);
      if(s == "")
         continue;
      int k = ArraySize(out);
      ArrayResize(out, k + 1);
      out[k] = s;
     }
  }

bool InList(const string s, const string &list[])
  {
   for(int i = 0; i < ArraySize(list); i++)
      if(StringCompare(s, list[i], false) == 0)
         return true;
   return false;
  }

bool IsSkipped(ulong tk)
  {
   for(int i = 0; i < ArraySize(g_skip); i++)
      if(g_skip[i] == tk)
         return true;
   return false;
  }

void Skip(ulong tk, const string why)
  {
   if(IsSkipped(tk))
      return;
   int n = ArraySize(g_skip);
   ArrayResize(g_skip, n + 1);
   g_skip[n] = tk;
   if(why != "")
      Log("Not copying master #" + IntegerToString((long)tk) + ": " + why);
  }

int AttemptIndex(ulong tk)
  {
   for(int i = 0; i < ArraySize(g_att); i++)
      if(g_att[i].tk == tk)
         return i;
   return -1;
  }

int RecordAttempt(ulong tk)
  {
   int i = AttemptIndex(tk);
   if(i < 0)
     {
      i = ArraySize(g_att);
      ArrayResize(g_att, i + 1);
      g_att[i].tk = tk;
      g_att[i].count = 0;
     }
   g_att[i].count++;
   g_att[i].last = GetTickCount64();
   return g_att[i].count;
  }

bool IsRecent(ulong tk)
  {
   ulong now = GetTickCount64();
   for(int i = 0; i < ArraySize(g_recent); i++)
      if(g_recent[i].tk == tk && now - g_recent[i].at < 10000)
         return true;
   return false;
  }

void AddRecent(ulong tk)
  {
   int n = ArraySize(g_recent);
   ArrayResize(g_recent, n + 1);
   g_recent[n].tk = tk;
   g_recent[n].at = GetTickCount64();
  }

bool InBackoff(ulong posTk)
  {
   ulong now = GetTickCount64();
   for(int i = 0; i < ArraySize(g_bo); i++)
      if(g_bo[i].tk == posTk && now < g_bo[i].until)
         return true;
   return false;
  }

void SetBackoff(ulong posTk, int ms)
  {
   ulong until = GetTickCount64() + (ulong)ms;
   for(int i = 0; i < ArraySize(g_bo); i++)
      if(g_bo[i].tk == posTk)
        {
         g_bo[i].until = until;
         return;
        }
   int n = ArraySize(g_bo);
   ArrayResize(g_bo, n + 1);
   g_bo[n].tk = posTk;
   g_bo[n].until = until;
  }

bool MasterHas(ulong tk)
  {
   for(int i = 0; i < g_mCount; i++)
      if(g_m[i].ticket == tk)
         return true;
   return false;
  }

// Drop bookkeeping for master tickets that no longer exist.
void Cleanup()
  {
   ulong now = GetTickCount64();
   for(int i = ArraySize(g_skip) - 1; i >= 0; i--)
      if(!MasterHas(g_skip[i]))
         ArrayRemove(g_skip, i, 1);
   for(int i = ArraySize(g_att) - 1; i >= 0; i--)
      if(!MasterHas(g_att[i].tk))
         ArrayRemove(g_att, i, 1);
   for(int i = ArraySize(g_recent) - 1; i >= 0; i--)
      if(now - g_recent[i].at >= 10000)
         ArrayRemove(g_recent, i, 1);
   for(int i = ArraySize(g_bo) - 1; i >= 0; i--)
      if(now >= g_bo[i].until)
         ArrayRemove(g_bo, i, 1);
  }

//+------------------------------------------------------------------+
//| Symbol mapping                                                   |
//+------------------------------------------------------------------+
void ParseSymbolMap()
  {
   ArrayResize(g_mapFrom, 0);
   ArrayResize(g_mapTo, 0);
   ArrayResize(g_mapMult, 0);
   string items[];
   int n = StringSplit(SymbolMap, ';', items);
   for(int i = 0; i < n; i++)
     {
      string it = Trim(items[i]);
      if(it == "")
         continue;
      string kv[];
      if(StringSplit(it, '=', kv) != 2)
        {
         Log("Ignoring bad SymbolMap entry: " + it);
         continue;
        }
      string to = Trim(kv[1]);
      double mult = 1.0;
      int star = StringFind(to, "*");
      if(star > 0)
        {
         mult = StringToDouble(StringSubstr(to, star + 1));
         to = Trim(StringSubstr(to, 0, star));
         if(mult <= 0)
            mult = 1.0;
        }
      int k = ArraySize(g_mapFrom);
      ArrayResize(g_mapFrom, k + 1);
      ArrayResize(g_mapTo, k + 1);
      ArrayResize(g_mapMult, k + 1);
      g_mapFrom[k] = Trim(kv[0]);
      g_mapTo[k]   = to;
      g_mapMult[k] = mult;
     }
  }

string MapSymbol(const string masterSym, double &mult)
  {
   mult = 1.0;
   for(int i = 0; i < ArraySize(g_mapFrom); i++)
      if(StringCompare(masterSym, g_mapFrom[i], false) == 0)
        {
         mult = g_mapMult[i];
         return g_mapTo[i];
        }
   string base = masterSym;
   int sl = StringLen(StripMasterSuffix);
   if(sl > 0 && StringLen(base) > sl &&
      StringCompare(StringSubstr(base, StringLen(base) - sl), StripMasterSuffix, false) == 0)
      base = StringSubstr(base, 0, StringLen(base) - sl);
   // A map entry can also target the stripped name.
   for(int i = 0; i < ArraySize(g_mapFrom); i++)
      if(StringCompare(base, g_mapFrom[i], false) == 0)
        {
         mult = g_mapMult[i];
         return g_mapTo[i];
        }
   return SymbolPrefix + base + SymbolSuffix;
  }

//+------------------------------------------------------------------+
//| Snapshot reading                                                 |
//+------------------------------------------------------------------+
bool ReadSnapshot()
  {
   int h = FileOpen(g_snapFile, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON |
                    FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE)
     {
      if(!FileIsExist(g_snapFile, FILE_COMMON))
         g_state = "WAITING FOR MASTER";
      return false;
     }
   MasterPos tmp[];
   int n = 0, endCount = -1;
   bool hdr = false, end = false;
   long seq = 0, t = 0, login = 0;
   double bal = 0, eq = 0;
   while(!FileIsEnding(h))
     {
      string ln = Trim(FileReadString(h));
      if(ln == "")
         continue;
      string f[];
      int k = StringSplit(ln, ',', f);
      if(k <= 0)
         continue;
      if(f[0] == "HDR" && k >= 7)
        {
         hdr   = true;
         seq   = StringToInteger(f[2]);
         t     = StringToInteger(f[3]);
         login = StringToInteger(f[4]);
         bal   = StringToDouble(f[5]);
         eq    = StringToDouble(f[6]);
        }
      else
         if(f[0] == "POS" && k >= 8 && hdr && !end)
           {
            ArrayResize(tmp, n + 1);
            tmp[n].ticket  = (ulong)StringToInteger(f[1]);
            tmp[n].symbol  = f[2];
            tmp[n].type    = (int)StringToInteger(f[3]);
            tmp[n].volume  = StringToDouble(f[4]);
            tmp[n].sl      = StringToDouble(f[5]);
            tmp[n].tp      = StringToDouble(f[6]);
            tmp[n].openGmt = StringToInteger(f[7]);
            n++;
           }
         else
            if(f[0] == "END" && k >= 2)
              {
               end = true;
               endCount = (int)StringToInteger(f[1]);
              }
     }
   FileClose(h);

   if(!hdr || !end || endCount != n)
      return false; // caught the master mid-write; use the next read

   ArrayResize(g_m, n);
   for(int i = 0; i < n; i++)
      g_m[i] = tmp[i];
   g_mCount   = n;
   g_hdrSeq   = seq;
   g_hdrTime  = t;
   g_hdrLogin = login;
   g_mBalance = bal;
   g_mEquity  = eq;
   return true;
  }

//+------------------------------------------------------------------+
//| Pause control written by the dashboard                           |
//+------------------------------------------------------------------+
void ReadControl()
  {
   bool paused = false;
   if(FileIsExist(g_controlFile, FILE_COMMON))
     {
      int h = FileOpen(g_controlFile, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON |
                       FILE_SHARE_READ | FILE_SHARE_WRITE);
      if(h == INVALID_HANDLE)
         return;
      string s = Trim(FileReadString(h));
      FileClose(h);
      paused = (s == "PAUSE=1");
     }
   if(paused != g_paused)
     {
      g_paused = paused;
      Log(paused ? "Paused from dashboard (no new trades; closes still mirrored)" : "Resumed from dashboard");
     }
  }

//+------------------------------------------------------------------+
//| Local position <-> master ticket link                            |
//| Stored in a terminal global variable, with the position comment  |
//| "TC|<master ticket>" as a fallback.                              |
//+------------------------------------------------------------------+
string GvName(const string kind, ulong posTk)
  {
   return "TC" + IntegerToString(CopierMagic) + kind + IntegerToString((long)posTk);
  }

void DeleteLink(ulong posTk)
  {
   GlobalVariableDel(GvName("m", posTk));
   GlobalVariableDel(GvName("mv", posTk));
   GlobalVariableDel(GvName("lv", posTk));
  }

// Position must already be selected.
ulong MasterTicketOf(ulong posTk)
  {
   string gv = GvName("m", posTk);
   if(GlobalVariableCheck(gv))
      return (ulong)GlobalVariableGet(gv);
   string c = PositionGetString(POSITION_COMMENT);
   if(StringFind(c, "TC|") == 0)
      return (ulong)StringToInteger(StringSubstr(c, 3));
   return 0;
  }

int CollectLocal(ulong &tks[], ulong &mts[])
  {
   ArrayResize(tks, 0);
   ArrayResize(mts, 0);
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || PositionGetInteger(POSITION_MAGIC) != CopierMagic)
         continue;
      ulong mt = MasterTicketOf(tk);
      if(mt == 0)
         continue;
      ArrayResize(tks, n + 1);
      ArrayResize(mts, n + 1);
      tks[n] = tk;
      mts[n] = mt;
      n++;
     }
   return n;
  }

//+------------------------------------------------------------------+
//| Helpers for prices and volumes                                   |
//+------------------------------------------------------------------+
bool TradeOk()
  {
   uint rc = trade.ResultRetcode();
   return rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED;
  }

string Res()
  {
   return IntegerToString(trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription();
  }

int VolDigits(double step)
  {
   int d = 0;
   while(d < 8 && MathAbs(step - MathRound(step)) > 1e-9)
     {
      step *= 10;
      d++;
     }
   return d;
  }

double NormVol(const string sym, double v)
  {
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(step <= 0)
      step = 0.01;
   v = MathFloor(v / step + 1e-7) * step;
   return NormalizeDouble(v, VolDigits(step));
  }

double CalcLot(double masterVol, const string sym, double symMult)
  {
   double lot = 0;
   switch(LotMode)
     {
      case TC_LOT_FIXED:
         lot = FixedLot;
         break;
      case TC_LOT_MULTIPLIER:
         lot = masterVol * Multiplier * symMult;
         break;
      case TC_LOT_BALANCE:
         if(g_mBalance > 0)
            lot = masterVol * AccountInfoDouble(ACCOUNT_BALANCE) / g_mBalance * Multiplier * symMult;
         break;
      case TC_LOT_EQUITY:
         if(g_mEquity > 0)
            lot = masterVol * AccountInfoDouble(ACCOUNT_EQUITY) / g_mEquity * Multiplier * symMult;
         break;
     }
   double mn = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(MaxLot > 0 && lot > MaxLot)
      lot = MaxLot;
   if(mx > 0 && lot > mx)
      lot = mx;
   lot = NormVol(sym, lot);
   if(lot < mn - 1e-9)
     {
      if(!UseMinLotIfTooSmall)
         return 0;
      lot = NormVol(sym, mn);
     }
   return lot;
  }

// Is this SL/TP price allowed right now for a position of this type?
bool StopValid(const string sym, int type, double price, bool isSL, const MqlTick &tick)
  {
   if(price <= 0)
      return true;
   double pt  = SymbolInfoDouble(sym, SYMBOL_POINT);
   double lvl = (double)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * pt;
   if(type == POSITION_TYPE_BUY)   // buys close at bid
      return isSL ? (price < tick.bid - lvl) : (price > tick.bid + lvl);
   return isSL ? (price > tick.ask + lvl) : (price < tick.ask - lvl);
  }

double NormPrice(const string sym, double p)
  {
   if(p <= 0)
      return 0;
   return NormalizeDouble(p, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));
  }

//+------------------------------------------------------------------+
//| Open a copy of a master position                                 |
//+------------------------------------------------------------------+
void TryOpen(const MasterPos &m)
  {
   if(IsSkipped(m.ticket) || IsRecent(m.ticket))
      return;
   if(ArraySize(g_only) > 0 && !InList(m.symbol, g_only))
     {
      Skip(m.ticket, "");
      return;
     }
   string mtk = "#" + IntegerToString((long)m.ticket);

   if(MaxOpenDelaySec > 0)
     {
      long age = (long)TimeGMT() - m.openGmt;
      if(age > MaxOpenDelaySec)
        {
         Skip(m.ticket, "opened " + IntegerToString(age) + "s ago (MaxOpenDelaySec=" + IntegerToString(MaxOpenDelaySec) + ")");
         return;
        }
     }

   double symMult;
   string sym = MapSymbol(m.symbol, symMult);
   if(!SymbolSelect(sym, true))
     {
      Skip(m.ticket, "symbol '" + sym + "' not found on this account (master: " + m.symbol + "). Add it to SymbolMap.");
      return;
     }

   int ai = AttemptIndex(m.ticket);
   if(ai >= 0 && GetTickCount64() - g_att[ai].last < 2000)
      return; // wait before retrying

   double lot = CalcLot(m.volume, sym, symMult);
   if(lot <= 0)
     {
      Skip(m.ticket, "calculated lot is below the broker minimum");
      return;
     }

   int type = m.type;
   if(Reverse)
      type = (type == POSITION_TYPE_BUY) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;

   MqlTick tick;
   if(!SymbolInfoTick(sym, tick) || tick.bid <= 0)
     {
      RecordAttempt(m.ticket);
      return;
     }

   double sl = 0, tp = 0;
   if(CopySLTP && !Reverse)
     {
      sl = NormPrice(sym, m.sl);
      tp = NormPrice(sym, m.tp);
      if(!StopValid(sym, type, sl, true, tick))
         sl = 0;
      if(!StopValid(sym, type, tp, false, tick))
         tp = 0;
     }

   trade.SetTypeFillingBySymbol(sym);
   string cmt = "TC|" + IntegerToString((long)m.ticket);
   bool sent = (type == POSITION_TYPE_BUY) ? trade.Buy(lot, sym, 0, sl, tp, cmt)
               : trade.Sell(lot, sym, 0, sl, tp, cmt);

   if(!(sent && TradeOk()) && trade.ResultRetcode() == TRADE_RETCODE_INVALID_STOPS && (sl > 0 || tp > 0))
     {
      // Open without stops; the sync loop will add them when they become valid.
      sent = (type == POSITION_TYPE_BUY) ? trade.Buy(lot, sym, 0, 0, 0, cmt)
             : trade.Sell(lot, sym, 0, 0, 0, cmt);
     }

   if(sent && TradeOk())
     {
      ulong posTk = trade.ResultOrder(); // on hedging accounts the position ticket = opening order ticket
      GlobalVariableSet(GvName("m", posTk), (double)m.ticket);
      GlobalVariableSet(GvName("mv", posTk), m.volume);
      GlobalVariableSet(GvName("lv", posTk), lot);
      GlobalVariablesFlush();
      AddRecent(m.ticket);
      int i = AttemptIndex(m.ticket);
      if(i >= 0)
         ArrayRemove(g_att, i, 1);
      Log(StringFormat("Copied master %s: %s %s %s lots (master %s) -> #%I64d",
                       mtk, (type == POSITION_TYPE_BUY ? "BUY" : "SELL"), sym,
                       DoubleToString(lot, 2), DoubleToString(m.volume, 2), (long)posTk));
     }
   else
     {
      int c = RecordAttempt(m.ticket);
      Log("Open failed for master " + mtk + " " + sym + " (attempt " + IntegerToString(c) + "): " + Res());
      if(c >= MaxOpenAttempts)
         Skip(m.ticket, "gave up after " + IntegerToString(c) + " failed attempts");
     }
  }

//+------------------------------------------------------------------+
//| Keep an existing copy in line with its master                    |
//+------------------------------------------------------------------+
void UpdatePos(ulong posTk, const MasterPos &m)
  {
   if(InBackoff(posTk) || !PositionSelectByTicket(posTk))
      return;
   string sym = PositionGetString(POSITION_SYMBOL);

   //--- partial close
   if(CopyPartialCloses)
     {
      string gmv = GvName("mv", posTk), glv = GvName("lv", posTk);
      if(GlobalVariableCheck(gmv) && GlobalVariableCheck(glv))
        {
         double mv0 = GlobalVariableGet(gmv);
         double lv0 = GlobalVariableGet(glv);
         if(mv0 > 0 && m.volume < mv0 - 1e-8)
           {
            double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
            double mn   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
            if(step <= 0)
               step = 0.01;
            double desired = MathRound(lv0 * m.volume / mv0 / step) * step;
            if(desired < mn)
               desired = mn;
            double cur = PositionGetDouble(POSITION_VOLUME);
            double cut = NormVol(sym, cur - desired);
            if(cut >= step - 1e-9 && cur - cut >= mn - 1e-9)
              {
               trade.SetTypeFillingBySymbol(sym);
               if(trade.PositionClosePartial(posTk, cut, SlippagePoints) && TradeOk())
                  Log("Partial close #" + IntegerToString((long)posTk) + " " + sym + " -" + DoubleToString(cut, 2) + " lots (master now " + DoubleToString(m.volume, 2) + ")");
               else
                 {
                  Log("Partial close failed #" + IntegerToString((long)posTk) + ": " + Res());
                  SetBackoff(posTk, 3000);
                 }
               return;
              }
           }
        }
     }

   //--- SL/TP sync
   if(!CopySLTP || Reverse)
      return;
   MqlTick tick;
   if(!SymbolInfoTick(sym, tick))
      return;
   int    type  = (int)PositionGetInteger(POSITION_TYPE);
   double pt    = SymbolInfoDouble(sym, SYMBOL_POINT);
   double curSL = PositionGetDouble(POSITION_SL);
   double curTP = PositionGetDouble(POSITION_TP);
   double mSL   = NormPrice(sym, m.sl);
   double mTP   = NormPrice(sym, m.tp);
   double newSL = curSL, newTP = curTP;
   if(MathAbs(mSL - curSL) > pt / 2 && (mSL == 0 || StopValid(sym, type, mSL, true, tick)))
      newSL = mSL;
   if(MathAbs(mTP - curTP) > pt / 2 && (mTP == 0 || StopValid(sym, type, mTP, false, tick)))
      newTP = mTP;
   if(newSL == curSL && newTP == curTP)
      return;
   if(trade.PositionModify(posTk, newSL, newTP) && TradeOk())
      Log("SL/TP updated #" + IntegerToString((long)posTk) + " " + sym + " SL " + DoubleToString(newSL, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)) + " TP " + DoubleToString(newTP, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)));
   else
     {
      Log("SL/TP update failed #" + IntegerToString((long)posTk) + ": " + Res());
      SetBackoff(posTk, 5000);
     }
  }

//+------------------------------------------------------------------+
void ClosePos(ulong posTk, ulong masterTk)
  {
   if(InBackoff(posTk) || !PositionSelectByTicket(posTk))
      return;
   string sym = PositionGetString(POSITION_SYMBOL);
   trade.SetTypeFillingBySymbol(sym);
   if(trade.PositionClose(posTk, SlippagePoints) && TradeOk())
     {
      DeleteLink(posTk);
      Log("Closed #" + IntegerToString((long)posTk) + " " + sym + " (master #" + IntegerToString((long)masterTk) + " closed)");
     }
   else
     {
      Log("Close failed #" + IntegerToString((long)posTk) + ": " + Res());
      SetBackoff(posTk, 3000);
     }
  }

//+------------------------------------------------------------------+
//| Main sync step                                                   |
//+------------------------------------------------------------------+
bool IsReady()
  {
   bool connected = (bool)TerminalInfoInteger(TERMINAL_CONNECTED);
   ulong now = GetTickCount64();
   if(!connected)
     {
      g_wasConnected = false;
      return false;
     }
   if(!g_wasConnected)
     {
      g_wasConnected = true;
      g_readyAt = now + (ulong)MathMax(0, SettleSec) * 1000;
     }
   return now >= g_readyAt;
  }

void Sync()
  {
   if(g_halted)
     {
      g_state = "HALTED";
      return;
     }
   if(!IsReady())
     {
      g_state = TerminalInfoInteger(TERMINAL_CONNECTED) ? "STARTING" : "DISCONNECTED";
      return;
     }
   if(!ReadSnapshot())
      return;

   long age = (long)TimeGMT() - g_hdrTime;
   if(age > StaleSec)
     {
      g_state = "MASTER OFFLINE";
      return; // never act on old data
     }
   if(ExpectedMasterLogin > 0 && g_hdrLogin != ExpectedMasterLogin)
     {
      Halt("master account " + IntegerToString(g_hdrLogin) + " is not ExpectedMasterLogin " + IntegerToString(ExpectedMasterLogin) + ".");
      return;
     }
   if(g_firstLogin == 0)
      g_firstLogin = g_hdrLogin;
   else
      if(g_hdrLogin != g_firstLogin)
        {
         Halt("master account changed from " + IntegerToString(g_firstLogin) + " to " + IntegerToString(g_hdrLogin) + ".");
         return;
        }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      g_state = "ALGO TRADING OFF";
      return;
     }
   g_state = g_paused ? "PAUSED" : "OK";

   ulong locTk[], locM[];
   int ln = CollectLocal(locTk, locM);

   //--- first run: leave trades that were already open alone
   if(!g_initialized)
     {
      g_initialized = true;
      if(!CopyExistingOnStart)
        {
         int skipped = 0;
         for(int j = 0; j < g_mCount; j++)
           {
            bool have = false;
            for(int i = 0; i < ln; i++)
               if(locM[i] == g_m[j].ticket)
                  have = true;
            if(!have)
              {
               Skip(g_m[j].ticket, "");
               skipped++;
              }
           }
         if(skipped > 0)
            Log("Ignoring " + IntegerToString(skipped) + " master trade(s) that were already open at start-up");
        }
     }

   //--- closes
   if(CopyCloses)
      for(int i = 0; i < ln; i++)
         if(!MasterHas(locM[i]))
            ClosePos(locTk[i], locM[i]);

   //--- opens and updates
   for(int j = 0; j < g_mCount; j++)
     {
      int idx = -1;
      for(int i = 0; i < ln; i++)
         if(locM[i] == g_m[j].ticket)
           {
            idx = i;
            break;
           }
      if(idx < 0)
        {
         if(!g_paused)
            TryOpen(g_m[j]);
        }
      else
         UpdatePos(locTk[idx], g_m[j]);
     }

   Cleanup();
  }

//+------------------------------------------------------------------+
//| Status file for the dashboard                                    |
//+------------------------------------------------------------------+
string Q(string s)
  {
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   return "\"" + s + "\"";
  }

void WriteStatus()
  {
   string j = "{";
   j += "\"role\":\"follower\",";
   j += "\"channel\":" + Q(Channel) + ",";
   j += "\"login\":" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ",";
   j += "\"name\":" + Q(AccountInfoString(ACCOUNT_NAME)) + ",";
   j += "\"server\":" + Q(AccountInfoString(ACCOUNT_SERVER)) + ",";
   j += "\"currency\":" + Q(AccountInfoString(ACCOUNT_CURRENCY)) + ",";
   j += "\"balance\":" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + ",";
   j += "\"equity\":" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + ",";
   j += "\"state\":" + Q(g_state) + ",";
   j += "\"paused\":" + (g_paused ? "true" : "false") + ",";
   j += "\"lotMode\":" + Q(EnumToString(LotMode)) + ",";
   j += "\"multiplier\":" + DoubleToString(Multiplier, 4) + ",";
   j += "\"masterLogin\":" + IntegerToString(g_hdrLogin) + ",";
   j += "\"masterAge\":" + IntegerToString(g_hdrTime > 0 ? (long)TimeGMT() - g_hdrTime : -1) + ",";
   j += "\"updated\":" + IntegerToString((long)TimeGMT()) + ",";
   j += "\"positions\":[";
   bool first = true;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || PositionGetInteger(POSITION_MAGIC) != CopierMagic)
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      if(!first)
         j += ",";
      first = false;
      j += "{\"ticket\":" + IntegerToString((long)tk) +
           ",\"masterTicket\":" + IntegerToString((long)MasterTicketOf(tk)) +
           ",\"symbol\":" + Q(sym) +
           ",\"type\":" + (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "\"BUY\"" : "\"SELL\"") +
           ",\"volume\":" + DoubleToString(PositionGetDouble(POSITION_VOLUME), 2) +
           ",\"sl\":" + DoubleToString(PositionGetDouble(POSITION_SL), dg) +
           ",\"tp\":" + DoubleToString(PositionGetDouble(POSITION_TP), dg) +
           ",\"profit\":" + DoubleToString(PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP), 2) + "}";
     }
   j += "],\"log\":[";
   for(int i = 0; i < ArraySize(g_log); i++)
     {
      if(i > 0)
         j += ",";
      j += Q(g_log[i]);
     }
   j += "]}";

   int h = FileOpen(g_statusFile, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
      return;
   FileWriteString(h, j);
   FileClose(h);
  }
//+------------------------------------------------------------------+
