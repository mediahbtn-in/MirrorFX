//+------------------------------------------------------------------+
//|                                                    TC_Master.mq5 |
//|  Trade Copier - MASTER                                           |
//|  Publishes this account's open positions to a shared file in     |
//|  the MT5 "Common\Files\TradeCopier" folder. TC_Follower EAs on   |
//|  other terminals (same Windows user) read it and mirror trades.  |
//+------------------------------------------------------------------+
#property copyright "Personal use"
#property version   "1.00"
#property description "Trade Copier MASTER - publishes open positions for TC_Follower."

input string Channel     = "main"; // Channel name (followers must use the same)
input int    TimerMs     = 25;     // Scan interval in milliseconds
input long   OnlyMagic   = -1;     // Publish only this magic number (-1 = all trades)
input string OnlySymbols = "";     // Publish only these symbols, comma separated (empty = all)
input int    SettleSec   = 3;      // Wait this long after start/reconnect before publishing

#define TC_DIR "TradeCopier"

string g_snapFile;
string g_statusFile;
string g_lastBody   = "";
ulong  g_lastWrite  = 0;
ulong  g_lastStatus = 0;
long   g_seq        = 0;
string g_only[];
ulong  g_readyAt    = 0;
bool   g_wasConnected = false;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(StringLen(Channel) == 0)
     {
      Alert("TC_Master: Channel must not be empty");
      return INIT_PARAMETERS_INCORRECT;
     }
   g_snapFile   = TC_DIR + "\\" + Channel + ".snap";
   g_statusFile = TC_DIR + "\\master_" + Channel + ".json";
   FolderCreate(TC_DIR, FILE_COMMON);
   ParseList(OnlySymbols, g_only);

   g_readyAt = GetTickCount64() + (ulong)MathMax(0, SettleSec) * 1000;
   g_wasConnected = (bool)TerminalInfoInteger(TERMINAL_CONNECTED);

   if(!EventSetMillisecondTimer(MathMax(10, TimerMs)))
     {
      Alert("TC_Master: could not start timer");
      return INIT_FAILED;
     }
   PrintFormat("[TC Master] channel '%s', account %I64d. Snapshot: Common\\Files\\%s",
               Channel, AccountInfoInteger(ACCOUNT_LOGIN), g_snapFile);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   // The snapshot file is intentionally left in place. Followers will see it
   // go stale and stop acting (they never close trades on a stale snapshot).
  }

void OnTick()  { Publish(false); }
void OnTimer()
  {
   Publish(false);
   ulong now = GetTickCount64();
   if(now - g_lastStatus >= 1000)
     {
      g_lastStatus = now;
      WriteStatus();
     }
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   Publish(false);
  }

//+------------------------------------------------------------------+
//| Is the terminal connected and settled? Right after start-up or a |
//| reconnect the position list may still be empty, and publishing   |
//| it would make followers close everything.                        |
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

//+------------------------------------------------------------------+
void ParseList(const string src, string &out[])
  {
   ArrayResize(out, 0);
   string parts[];
   int n = StringSplit(src, ',', parts);
   for(int i = 0; i < n; i++)
     {
      string s = parts[i];
      StringTrimLeft(s);
      StringTrimRight(s);
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

// Selected position passes the filters?
bool Wanted()
  {
   if(OnlyMagic >= 0 && PositionGetInteger(POSITION_MAGIC) != OnlyMagic)
      return false;
   if(ArraySize(g_only) > 0 && !InList(PositionGetString(POSITION_SYMBOL), g_only))
      return false;
   return true;
  }

// Broker server time minus GMT, rounded to the nearest 30 minutes.
long ServerOffset()
  {
   long diff = (long)TimeTradeServer() - (long)TimeGMT();
   return (long)MathRound(diff / 1800.0) * 1800;
  }

//+------------------------------------------------------------------+
//| Snapshot format (one line each):                                 |
//|   HDR,1,<seq>,<gmt>,<login>,<balance>,<equity>                   |
//|   POS,<ticket>,<symbol>,<type 0=buy 1=sell>,<vol>,<sl>,<tp>,<openGmt>
//|   END,<count>                                                    |
//| Followers ignore the file unless END is present and the count    |
//| matches, so a half-written file is never acted on.               |
//+------------------------------------------------------------------+
void Publish(bool force)
  {
   if(!IsReady())
      return;

   string body = "";
   int n = 0;
   long offset = ServerOffset();
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !Wanted())
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      body += "POS," + IntegerToString((long)tk) + "," + sym + "," +
              IntegerToString(PositionGetInteger(POSITION_TYPE)) + "," +
              DoubleToString(PositionGetDouble(POSITION_VOLUME), 8) + "," +
              DoubleToString(PositionGetDouble(POSITION_SL), dg) + "," +
              DoubleToString(PositionGetDouble(POSITION_TP), dg) + "," +
              IntegerToString((long)PositionGetInteger(POSITION_TIME) - offset) + "\n";
      n++;
     }

   ulong now = GetTickCount64();
   // Rewrite on any change, otherwise once a second as a heartbeat.
   if(!force && body == g_lastBody && now - g_lastWrite < 1000)
      return;

   g_seq++;
   string out = "HDR,1," + IntegerToString(g_seq) + "," +
                IntegerToString((long)TimeGMT()) + "," +
                IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "," +
                DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "," +
                DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + "\n" +
                body + "END," + IntegerToString(n) + "\n";

   int h = FileOpen(g_snapFile, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
      return; // a follower is reading right now; try again on the next tick
   FileWriteString(h, out);
   FileClose(h);
   g_lastBody  = body;
   g_lastWrite = now;
  }

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
   j += "\"role\":\"master\",";
   j += "\"channel\":" + Q(Channel) + ",";
   j += "\"login\":" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ",";
   j += "\"name\":" + Q(AccountInfoString(ACCOUNT_NAME)) + ",";
   j += "\"server\":" + Q(AccountInfoString(ACCOUNT_SERVER)) + ",";
   j += "\"currency\":" + Q(AccountInfoString(ACCOUNT_CURRENCY)) + ",";
   j += "\"balance\":" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + ",";
   j += "\"equity\":" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + ",";
   j += "\"connected\":" + (TerminalInfoInteger(TERMINAL_CONNECTED) ? "true" : "false") + ",";
   j += "\"publishing\":" + (IsReady() ? "true" : "false") + ",";
   j += "\"updated\":" + IntegerToString((long)TimeGMT()) + ",";
   j += "\"positions\":[";
   bool first = true;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !Wanted())
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      if(!first)
         j += ",";
      first = false;
      j += "{\"ticket\":" + IntegerToString((long)tk) +
           ",\"symbol\":" + Q(sym) +
           ",\"type\":" + (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "\"BUY\"" : "\"SELL\"") +
           ",\"volume\":" + DoubleToString(PositionGetDouble(POSITION_VOLUME), 2) +
           ",\"sl\":" + DoubleToString(PositionGetDouble(POSITION_SL), dg) +
           ",\"tp\":" + DoubleToString(PositionGetDouble(POSITION_TP), dg) +
           ",\"profit\":" + DoubleToString(PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP), 2) + "}";
     }
   j += "]}";

   int h = FileOpen(g_statusFile, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
      return;
   FileWriteString(h, j);
   FileClose(h);
  }
//+------------------------------------------------------------------+
