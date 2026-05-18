//+------------------------------------------------------------------+
//|                                                  RecoveryEA.mq5  |
//|         Drawdown recovery / basket-averaging EA for MT5          |
//|                                                                  |
//|  Designed to be attached to an account that's already in deep    |
//|  drawdown. It adopts existing positions on the chart symbol,     |
//|  adds carefully scaled averaging trades when price moves further |
//|  against the basket, and closes the basket when total floating   |
//|  P/L reaches the configured target. Optional smart-partial close |
//|  pairs the best winner with the worst loser to peel off paired   |
//|  trades when their combined P/L is positive. A hard equity stop  |
//|  freezes the EA if drawdown deepens past the configured limit.   |
//|                                                                  |
//|  WARNING: averaging / grid recovery is fundamentally risky.      |
//|  Defaults are conservative (multiplier 1.3, basket cap 5.0 lot,  |
//|  hard equity stop -25% from attach). Tune to YOUR account.       |
//|                                                                  |
//|  v1.10 — additions over v1.00:                                   |
//|    * Optional EvasiveST_FBG indicator filter on the FIRST add    |
//|      of an empty side (prevents averaging into a clearly wrong   |
//|      direction). Pulls the indicator's calc-buffer #14 (Trend)   |
//|      from current TF or HTF.                                     |
//|    * Trailing target: once the basket P/L exceeds the take-      |
//|      profit, EA does not close immediately; it lets P/L grow     |
//|      and only closes when P/L retraces by InpTrailGiveback from  |
//|      the recorded peak. Per-side state, reset on basket close.   |
//|                                                                  |
//|  v1.20 — Алиса handoff (Variant 2):                              |
//|    * Adoption can be restricted to a CSV list of magics          |
//|      (InpAdoptionMode=ADOPT_BY_MAGIC_LIST). Recovery picks up    |
//|      ONLY positions opened by listed Алиса strategies.           |
//|    * Reads GV "Alisa.Halt" — if 0, Recovery stays passive        |
//|      (InpHandoffOnlyWhenAlisaHalted=true).                       |
//|    * Sets GV "Alisa.Recovery.Active" to 1 while there are        |
//|      adopted positions; clears to 0 when basket is empty,        |
//|      so Алиса can resume.                                        |
//+------------------------------------------------------------------+
#property copyright "Swill Way"
#property version   "1.20"
#property description "Recovery EA: adopts losing basket on chart symbol, ATR/pip averaging, basket-TP with trailing, best+worst partial close, ST-direction filter, hard equity stop, Алиса handoff."

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>
#include <Trade/PositionInfo.mqh>

CTrade        Trade;
CSymbolInfo   Sym;
CPositionInfo Pos;

enum ENUM_STEP_MODE   { STEP_PIPS=0, STEP_ATR=1 };
enum ENUM_TP_MODE     { TP_MONEY=0, TP_PERCENT_BAL=1, TP_PIPS_WEIGHTED=2 };
enum ENUM_ST_FILTER   { ST_FILTER_NONE=0, ST_FILTER_LTF=1, ST_FILTER_HTF=2 };
enum ENUM_ADOPT_MODE  { ADOPT_OWN_MAGIC=0, ADOPT_ALL_FOREIGN=1, ADOPT_BY_MAGIC_LIST=2 };

//================== Inputs ==========================================
input group "=== Идентификация ==="
input long   InpMagic            = 770077;   // Magic для новых ордеров (усреднения)
input bool   InpAdoptForeign     = true;     // [LEGACY] Игнорируется при InpAdoptionMode != ADOPT_OWN_MAGIC
input ENUM_ADOPT_MODE InpAdoptionMode = ADOPT_BY_MAGIC_LIST; // Какие позиции брать на сопровождение
input string InpAdoptMagicsCSV   = "852791,852792,852793";   // Список магиков (для ADOPT_BY_MAGIC_LIST)
input string InpComment          = "Recovery";

input group "=== Область восстановления ==="
input bool   InpManageBuys       = true;     // Управлять корзиной BUY
input bool   InpManageSells      = true;     // Управлять корзиной SELL

input group "=== Шаг усреднения ==="
input ENUM_STEP_MODE  InpStepMode = STEP_ATR;
input double InpStepPips         = 200;      // Шаг в пипсах (для STEP_PIPS)
input int    InpAtrPeriod        = 14;       // Период ATR (для STEP_ATR)
input ENUM_TIMEFRAMES InpAtrTF   = PERIOD_H1;// ТФ для ATR
input double InpAtrMult          = 1.0;      // Шаг = ATR * mult
input double InpStepGrowth       = 1.0;      // Шаг растёт ×factor с каждым уровнем (1.0 = фикс)

input group "=== Масштабирование лота ==="
input double InpLotMultiplier    = 1.3;      // Следующий лот = max(лот в корзине) * множитель
input double InpLotAdd           = 0.0;      // ИЛИ линейная добавка к последнему лоту (0 = только множитель)
input double InpMaxLotPerTrade   = 1.0;      // Жёсткий потолок на одну добавку
input double InpMaxBasketVolume  = 5.0;      // Жёсткий потолок суммарного лота корзины

input group "=== Тейк-профит корзины ==="
input ENUM_TP_MODE InpTpMode     = TP_MONEY;
input double InpTpMoney          = 50.0;     // Цель в валюте депозита
input double InpTpPercentBal     = 1.0;      // ИЛИ % от баланса
input double InpTpPipsWeighted   = 30;       // ИЛИ средние пипсы выше взвешенной точки входа

input group "=== Trailing target ==="
input bool   InpTrailEnabled     = true;     // Не закрывать сразу по достижении TP — тащить пик
input double InpTrailGivebackAbs = 0.0;      // Закрыть, если PL упал ниже пика на X (валюта депо). 0 = не использовать
input double InpTrailGivebackPct = 30.0;     // ИЛИ % от пика PL (применяется если TrailGivebackAbs=0)
input double InpTrailMinPL       = 0.0;      // Не активировать трейл, пока PL не превысит этот абсолютный минимум

input group "=== Smart partial close ==="
input bool   InpSmartPartial     = true;     // Закрывать «худший минус + лучший плюс» когда сумма ≥ доли цели
input double InpPartialFraction  = 0.3;      // Пара должна давать не менее этой доли цели корзины
input int    InpMinTradesForPart = 4;        // Минимум сделок в корзине для активации

input group "=== Кросс-корзина (хедж) ==="
input bool   InpCrossBasketClose = false;    // Если есть и BUY и SELL — закрыть всё, когда сумма PL ≥ цели

input group "=== Фильтр Evasive SuperTrend ==="
input ENUM_ST_FILTER InpSTFilter = ST_FILTER_NONE; // Применять ли фильтр направления СуперТренда
input string InpSTIndicatorName  = "EvasiveST_FBG"; // Имя файла индикатора (без .ex5) в Indicators
input ENUM_TIMEFRAMES InpSTTimeframe = PERIOD_H1;   // ТФ для фильтра (используется при ST_FILTER_HTF)
//--- параметры ниже должны совпадать с теми, что выставлены на графике
input int    InpST_AtrLength     = 10;
input double InpST_BaseMultiplier= 3.0;
input double InpST_NoiseThreshold= 1.0;
input double InpST_ExpansionAlpha= 0.5;
input bool   InpST_EvasionPersist= true;

input group "=== Риск-капы ==="
input double InpMaxAttachDDPct   = 25.0;     // Hard stop: equity опустилась ниже equity-на-аттач на N% → закрыть всё
input double InpMinEquityFloor   = 0.0;      // Абсолютный пол equity (0 = не использовать)
input bool   InpFreezeOnHardStop = true;     // После hard stop EA остаётся выключенным до перезапуска
input int    InpMaxTradesInGrid  = 12;       // Макс позиций в одной стороне

input group "=== Тайминг ==="
input int    InpAddCooldownSec   = 30;       // Минимальная пауза между добавками (на каждую сторону)
input int    InpTimerSec         = 2;        // Внутренний таймер для проверок без тика

input group "=== Алиса handoff ==="
input bool   InpHandoffEnabled              = true;   // Слушать GV Alisa.Halt и публиковать Alisa.Recovery.Active
input bool   InpHandoffOnlyWhenAlisaHalted  = true;   // Работать ТОЛЬКО когда Alisa.Halt=1 (иначе пассивно)
input bool   InpHandoffPublishActive        = true;   // Публиковать GV Alisa.Recovery.Active

//================== State ===========================================
int      g_atrHandle      = INVALID_HANDLE;
int      g_stHandle       = INVALID_HANDLE;
double   g_attachEquity   = 0.0;
bool     g_frozen         = false;
datetime g_lastAddTime[2] = {0,0};   // [0]=BUY, [1]=SELL

//--- trailing-target state (per side; reset when basket goes to 0)
double   g_peakProfit[2]    = {0.0, 0.0};
bool     g_trailArmed[2]    = {false, false};

//--- handoff state
const string GV_HANDOFF_HALT     = "Alisa.Halt";
const string GV_HANDOFF_EQUITY   = "Alisa.AttachEquity";
const string GV_HANDOFF_ACTIVE   = "Alisa.Recovery.Active";

//--- adoption magic-list cache (parsed from InpAdoptMagicsCSV at init)
ulong  g_adoptMagics[];
int    g_adoptMagicsCount = 0;

//================== Helpers =========================================
double PipSize()
{
   int    d  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return (d==3 || d==5) ? pt*10.0 : pt;
}

double NormalizeLot(double v)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = 0.01;
   if(v < minLot) v = minLot;
   if(v > maxLot) v = maxLot;
   v = MathFloor(v/step)*step;
   int digits = (int)MathRound(-MathLog10(step));
   return NormalizeDouble(v, digits);
}

struct BasketInfo
{
   int      count;
   double   totalVolume;
   double   avgPrice;       // объёмно-взвешенная средняя
   double   worstPrice;     // BUY: min open; SELL: max open — точка отсчёта для шага
   double   maxVolume;      // максимальный лот в корзине
   datetime lastTime;
   double   profit;         // PL + swap
   double   pipValuePerLot; // для TP_PIPS_WEIGHTED
};

bool BelongsToBasket(const ulong ticket)
{
   if(!Pos.SelectByTicket(ticket)) return false;
   if(Pos.Symbol() != _Symbol)     return false;

   ulong m = Pos.Magic();
   switch(InpAdoptionMode)
   {
      case ADOPT_OWN_MAGIC:
         return (m == (ulong)InpMagic);

      case ADOPT_ALL_FOREIGN:
         return true;

      case ADOPT_BY_MAGIC_LIST:
      {
         if(m == (ulong)InpMagic) return true;   // свои усреднения тоже принимаем
         for(int i = 0; i < g_adoptMagicsCount; ++i)
            if(g_adoptMagics[i] == m) return true;
         return false;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Parse CSV "852791,852792,852793" into g_adoptMagics              |
//+------------------------------------------------------------------+
void ParseAdoptMagicsCSV(const string csv)
{
   ArrayResize(g_adoptMagics, 0);
   g_adoptMagicsCount = 0;

   string parts[];
   int n = StringSplit(csv, ',', parts);
   if(n <= 0) return;

   ArrayResize(g_adoptMagics, n);
   for(int i = 0; i < n; ++i)
   {
      string s = parts[i];
      StringTrimLeft(s); StringTrimRight(s);
      if(StringLen(s) == 0) continue;
      long v = StringToInteger(s);
      if(v <= 0) continue;
      g_adoptMagics[g_adoptMagicsCount++] = (ulong)v;
   }
   ArrayResize(g_adoptMagics, g_adoptMagicsCount);
}

//+------------------------------------------------------------------+
//| Алиса handoff — read/write GVs                                   |
//+------------------------------------------------------------------+
bool HandoffAlisaHalted()
{
   if(!InpHandoffEnabled) return false;
   if(!GlobalVariableCheck(GV_HANDOFF_HALT)) return false;
   return GlobalVariableGet(GV_HANDOFF_HALT) > 0.5;
}

void HandoffPublishActive(bool active)
{
   if(!InpHandoffEnabled || !InpHandoffPublishActive) return;
   if(active)
   {
      GlobalVariableSet(GV_HANDOFF_ACTIVE, 1.0);
      GlobalVariableTemp(GV_HANDOFF_ACTIVE);
   }
   else
   {
      if(GlobalVariableCheck(GV_HANDOFF_ACTIVE))
         GlobalVariableSet(GV_HANDOFF_ACTIVE, 0.0);
   }
}

void CalcBasket(const ENUM_POSITION_TYPE wantType, BasketInfo &b)
{
   ZeroMemory(b);
   double sumVolPrice = 0.0;

   int total = PositionsTotal();
   for(int i=0; i<total; ++i)
   {
      ulong ticket = PositionGetTicket(i);
      if(!BelongsToBasket(ticket))     continue;
      if(Pos.PositionType() != wantType) continue;

      double v = Pos.Volume();
      double p = Pos.PriceOpen();

      b.count++;
      b.totalVolume += v;
      sumVolPrice   += v * p;
      b.profit      += Pos.Profit() + Pos.Swap();
      if(v > b.maxVolume) b.maxVolume = v;

      datetime t = (datetime)Pos.Time();
      if(t > b.lastTime) b.lastTime = t;

      if(b.count == 1)                                                b.worstPrice = p;
      else if(wantType == POSITION_TYPE_BUY  && p < b.worstPrice)     b.worstPrice = p;
      else if(wantType == POSITION_TYPE_SELL && p > b.worstPrice)     b.worstPrice = p;
   }
   if(b.totalVolume > 0)
      b.avgPrice = sumVolPrice / b.totalVolume;

   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pip      = PipSize();
   if(tickSize > 0) b.pipValuePerLot = tickVal / tickSize * pip;
}

double GetStepPrice(int level)
{
   double base;
   if(InpStepMode == STEP_ATR)
   {
      double atr[];
      if(CopyBuffer(g_atrHandle, 0, 0, 1, atr) < 1) return 0.0;
      base = atr[0] * InpAtrMult;
   }
   else
      base = InpStepPips * PipSize();

   if(InpStepGrowth > 1.0 && level > 0)
      base *= MathPow(InpStepGrowth, level);
   return base;
}

double NextLot(double baseLot)
{
   double v = (InpLotAdd > 0.0) ? (baseLot + InpLotAdd) : (baseLot * InpLotMultiplier);
   if(v > InpMaxLotPerTrade) v = InpMaxLotPerTrade;
   return NormalizeLot(v);
}

double BasketTpTarget(const BasketInfo &b)
{
   switch(InpTpMode)
   {
      case TP_MONEY:         return InpTpMoney;
      case TP_PERCENT_BAL:   return AccountInfoDouble(ACCOUNT_BALANCE) * InpTpPercentBal/100.0;
      case TP_PIPS_WEIGHTED: return InpTpPipsWeighted * b.totalVolume * b.pipValuePerLot;
   }
   return InpTpMoney;
}

//+------------------------------------------------------------------+
//| Evasive SuperTrend filter                                        |
//|   Reads calc-buffer #14 (Trend) of the indicator from the file    |
//|   InpSTIndicatorName on the requested timeframe. Returns +1/-1/0. |
//+------------------------------------------------------------------+
int STTrendNow()
{
   if(InpSTFilter == ST_FILTER_NONE) return 0;
   if(g_stHandle == INVALID_HANDLE)  return 0;

   double t[];
   // buffer 14 in EvasiveST_FBG.mq5 == BufTrend (CALCULATIONS).
   // shift 1 → last fully closed bar, look-ahead-safe.
   if(CopyBuffer(g_stHandle, 14, 1, 1, t) < 1) return 0;
   double v = t[0];
   if(v >  0.5) return  1;
   if(v < -0.5) return -1;
   return 0;
}

bool STAllowsFirstEntry(ENUM_POSITION_TYPE dir, int basketCount)
{
   if(InpSTFilter == ST_FILTER_NONE) return true;
   if(basketCount > 0)               return true;   // фильтр только на ПЕРВЫЙ вход
   int tr = STTrendNow();
   if(tr == 0) return false;                        // нет данных — не открываем
   return (dir == POSITION_TYPE_BUY) ? (tr == 1) : (tr == -1);
}

//+------------------------------------------------------------------+
//| Trailing target                                                  |
//+------------------------------------------------------------------+
int SideIdx(ENUM_POSITION_TYPE dir) { return (dir==POSITION_TYPE_BUY) ? 0 : 1; }

void ResetTrail(ENUM_POSITION_TYPE dir)
{
   int s = SideIdx(dir);
   g_peakProfit[s] = 0.0;
   g_trailArmed[s] = false;
}

//+------------------------------------------------------------------+
//| Trade primitives                                                 |
//+------------------------------------------------------------------+
void CloseSide(ENUM_POSITION_TYPE dir)
{
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong tk = PositionGetTicket(i);
      if(!BelongsToBasket(tk))   continue;
      if(Pos.PositionType()!=dir) continue;
      Trade.PositionClose(tk);
   }
   ResetTrail(dir);
}

void CloseAllManaged()
{
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong tk = PositionGetTicket(i);
      if(!BelongsToBasket(tk)) continue;
      Trade.PositionClose(tk);
   }
   ResetTrail(POSITION_TYPE_BUY);
   ResetTrail(POSITION_TYPE_SELL);
}

void TryAverage(ENUM_POSITION_TYPE dir, const BasketInfo &b)
{
   if(b.count == 0)                          return;
   if(b.count >= InpMaxTradesInGrid)         return;
   if(b.totalVolume >= InpMaxBasketVolume)   return;
   if(!STAllowsFirstEntry(dir, b.count))     return;  // на пустую сторону — только по тренду

   int sIdx = SideIdx(dir);
   if(TimeCurrent() - g_lastAddTime[sIdx] < InpAddCooldownSec) return;

   double step = GetStepPrice(b.count - 1);
   if(step <= 0) return;

   if(!Sym.RefreshRates()) return;
   double price = (dir==POSITION_TYPE_BUY) ? Sym.Ask() : Sym.Bid();

   bool trigger = (dir==POSITION_TYPE_BUY)
                  ? (b.worstPrice - price) >= step
                  : (price - b.worstPrice) >= step;
   if(!trigger) return;

   double lot  = NextLot(b.maxVolume);
   double room = InpMaxBasketVolume - b.totalVolume;
   if(lot > room) lot = NormalizeLot(room);
   if(lot < SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)) return;

   bool ok = (dir==POSITION_TYPE_BUY)
             ? Trade.Buy (lot, _Symbol, 0.0, 0.0, 0.0, InpComment)
             : Trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, InpComment);
   if(ok) g_lastAddTime[sIdx] = TimeCurrent();
   else   PrintFormat("Average %s failed: %d %s",
                      (dir==POSITION_TYPE_BUY)?"BUY":"SELL",
                      Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Basket close with optional trailing-target                       |
//+------------------------------------------------------------------+
void TryCloseBasket(ENUM_POSITION_TYPE dir, const BasketInfo &b)
{
   if(b.count == 0) { ResetTrail(dir); return; }

   double tgt = BasketTpTarget(b);
   int    s   = SideIdx(dir);

   if(!InpTrailEnabled)
   {
      if(b.profit >= tgt)
      {
         PrintFormat("Close %s basket: PL=%.2f >= target=%.2f  vol=%.2f n=%d",
                     (dir==POSITION_TYPE_BUY)?"BUY":"SELL",
                     b.profit, tgt, b.totalVolume, b.count);
         CloseSide(dir);
      }
      return;
   }

   //--- trailing-target branch
   //    1) пока PL < target И трейл ещё не вооружён — ничего не делаем
   //    2) когда PL ≥ target и > InpTrailMinPL — арм трейла, начинаем тащить пик
   //    3) после арма: обновляем peak; закрываем, когда PL опускается ниже
   //       порога giveback от пика
   if(!g_trailArmed[s])
   {
      if(b.profit >= tgt && b.profit > InpTrailMinPL)
      {
         g_trailArmed[s] = true;
         g_peakProfit[s] = b.profit;
         PrintFormat("Trail ARM %s: peak=%.2f (target was %.2f)",
                     (dir==POSITION_TYPE_BUY)?"BUY":"SELL", b.profit, tgt);
      }
      return;
   }

   if(b.profit > g_peakProfit[s])
      g_peakProfit[s] = b.profit;

   double giveback = (InpTrailGivebackAbs > 0.0)
                     ? InpTrailGivebackAbs
                     : g_peakProfit[s] * InpTrailGivebackPct/100.0;
   double trigger  = g_peakProfit[s] - giveback;

   //--- защитный пол: даже после отдачи прибыли не закрываемся в минусе,
   //    раз цель когда-то была достигнута. Если цель была положительной —
   //    держим хотя бы безубыток.
   if(tgt > 0.0 && trigger < 0.0) trigger = 0.0;

   if(b.profit <= trigger)
   {
      PrintFormat("Trail CLOSE %s: PL=%.2f, peak=%.2f, giveback=%.2f -> trigger=%.2f",
                  (dir==POSITION_TYPE_BUY)?"BUY":"SELL",
                  b.profit, g_peakProfit[s], giveback, trigger);
      CloseSide(dir);
   }
}

void TrySmartPartial(ENUM_POSITION_TYPE dir, const BasketInfo &b)
{
   if(!InpSmartPartial)                  return;
   if(b.count < InpMinTradesForPart)     return;

   double partTarget = BasketTpTarget(b) * InpPartialFraction;

   ulong  bestT=0, worstT=0;
   double bestP=-DBL_MAX, worstP=DBL_MAX;

   int total = PositionsTotal();
   for(int i=0; i<total; ++i)
   {
      ulong tk = PositionGetTicket(i);
      if(!BelongsToBasket(tk))    continue;
      if(Pos.PositionType()!=dir) continue;
      double pr = Pos.Profit() + Pos.Swap();
      if(pr > bestP)  { bestP  = pr; bestT  = tk; }
      if(pr < worstP) { worstP = pr; worstT = tk; }
   }
   if(bestT==0 || worstT==0 || bestT==worstT) return;
   if(bestP <= 0)                              return;
   if(worstP >= 0)                             return;
   if(bestP + worstP < partTarget)             return;

   PrintFormat("Smart partial %s: WIN #%I64u (%+.2f) + LOSS #%I64u (%+.2f) = %+.2f >= %+.2f",
               (dir==POSITION_TYPE_BUY)?"BUY":"SELL",
               bestT, bestP, worstT, worstP, bestP+worstP, partTarget);
   Trade.PositionClose(bestT);
   Trade.PositionClose(worstT);
}

void TryCrossBasketClose(const BasketInfo &bb, const BasketInfo &sb)
{
   if(!InpCrossBasketClose)            return;
   if(bb.count == 0 || sb.count == 0)  return;
   double total  = bb.profit + sb.profit;
   double target = MathMax(BasketTpTarget(bb), BasketTpTarget(sb));
   if(total >= target)
   {
      PrintFormat("Cross-basket close: PL=%.2f >= %.2f", total, target);
      CloseAllManaged();
   }
}

void CheckHardStop()
{
   if(g_frozen) return;
   double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
   bool   trip = false;
   if(InpMaxAttachDDPct > 0.0)
   {
      double floor = g_attachEquity * (1.0 - InpMaxAttachDDPct/100.0);
      if(eq < floor) trip = true;
   }
   if(InpMinEquityFloor > 0.0 && eq < InpMinEquityFloor) trip = true;

   if(trip)
   {
      PrintFormat("HARD STOP: equity %.2f below safety threshold. Closing all managed positions.", eq);
      CloseAllManaged();
      if(InpFreezeOnHardStop) g_frozen = true;
   }
}

void UpdateChartLabel(const BasketInfo &bb, const BasketInfo &sb)
{
   string trail = "";
   if(InpTrailEnabled)
      trail = StringFormat("\nTrail BUY: armed=%s peak=%+.2f | SELL: armed=%s peak=%+.2f",
                           g_trailArmed[0] ? "Y" : "N", g_peakProfit[0],
                           g_trailArmed[1] ? "Y" : "N", g_peakProfit[1]);

   string st = "";
   if(InpSTFilter != ST_FILTER_NONE)
   {
      int tr = STTrendNow();
      string s = (tr>0)?"Up" : (tr<0?"Dn":"--");
      st = StringFormat("\nST filter [%s %s]: %s",
                        (InpSTFilter==ST_FILTER_LTF)?"LTF":"HTF",
                        EnumToString(InpSTTimeframe), s);
   }

   string ho = "";
   if(InpHandoffEnabled)
   {
      bool halted = HandoffAlisaHalted();
      bool active = (bb.count > 0 || sb.count > 0);
      ho = StringFormat("\nHandoff: AlisaHalt=%s | RecoveryActive=%s | Adoption=%s (n=%d)",
                        halted ? "1" : "0",
                        active ? "1" : "0",
                        (InpAdoptionMode == ADOPT_OWN_MAGIC)     ? "OWN"
                       :(InpAdoptionMode == ADOPT_ALL_FOREIGN)   ? "ALL"
                       :                                          "LIST",
                        g_adoptMagicsCount);
   }

   string text = StringFormat(
      "Recovery EA  |  Eq=%.2f  Bal=%.2f  AttachEq=%.2f%s\n"
      "BUY:  n=%d  vol=%.2f  avg=%.5f  worst=%.5f  P/L=%+.2f\n"
      "SELL: n=%d  vol=%.2f  avg=%.5f  worst=%.5f  P/L=%+.2f%s%s%s",
      AccountInfoDouble(ACCOUNT_EQUITY),
      AccountInfoDouble(ACCOUNT_BALANCE),
      g_attachEquity,
      g_frozen ? "  [FROZEN]" : "",
      bb.count, bb.totalVolume, bb.avgPrice, bb.worstPrice, bb.profit,
      sb.count, sb.totalVolume, sb.avgPrice, sb.worstPrice, sb.profit,
      trail, st, ho);
   Comment(text);
}

void Cycle()
{
   if(!Sym.RefreshRates()) return;

   CheckHardStop();
   if(g_frozen) { Comment("Recovery EA: FROZEN (hard stop). Restart EA to re-enable."); return; }

   BasketInfo bb, sb;
   CalcBasket(POSITION_TYPE_BUY,  bb);
   CalcBasket(POSITION_TYPE_SELL, sb);

   //--- HANDOFF: если включён, и Алиса не в halt, и режим «работать только в halt» —
   //    сидим тихо. Не открываем, не закрываем, лишь публикуем Active=0.
   bool alisaHalted   = HandoffAlisaHalted();
   bool weHavePos     = (bb.count > 0 || sb.count > 0);

   if(InpHandoffEnabled && InpHandoffOnlyWhenAlisaHalted && !alisaHalted && !weHavePos)
   {
      HandoffPublishActive(false);
      UpdateChartLabel(bb, sb);
      return;
   }

   //--- сбрасываем трейл-стейт, если корзина пустая
   if(bb.count == 0) ResetTrail(POSITION_TYPE_BUY);
   if(sb.count == 0) ResetTrail(POSITION_TYPE_SELL);

   TryCrossBasketClose(bb, sb);
   CalcBasket(POSITION_TYPE_BUY,  bb);
   CalcBasket(POSITION_TYPE_SELL, sb);

   if(InpManageBuys)
   {
      TryCloseBasket(POSITION_TYPE_BUY, bb);                   CalcBasket(POSITION_TYPE_BUY, bb);
      if(bb.count > 0) { TrySmartPartial(POSITION_TYPE_BUY, bb); CalcBasket(POSITION_TYPE_BUY, bb); }
      TryAverage(POSITION_TYPE_BUY, bb);
   }
   if(InpManageSells)
   {
      TryCloseBasket(POSITION_TYPE_SELL, sb);                  CalcBasket(POSITION_TYPE_SELL, sb);
      if(sb.count > 0) { TrySmartPartial(POSITION_TYPE_SELL, sb); CalcBasket(POSITION_TYPE_SELL, sb); }
      TryAverage(POSITION_TYPE_SELL, sb);
   }

   CalcBasket(POSITION_TYPE_BUY,  bb);
   CalcBasket(POSITION_TYPE_SELL, sb);

   //--- HANDOFF: публикуем Active = есть ли у нас сопровождаемые позиции
   HandoffPublishActive(bb.count > 0 || sb.count > 0);

   UpdateChartLabel(bb, sb);
}

//================== Init/deinit/event ==============================
int OnInit()
{
   if(!Sym.Name(_Symbol)) { Print("Symbol init failed"); return INIT_FAILED; }
   Sym.RefreshRates();

   Trade.SetExpertMagicNumber((ulong)InpMagic);
   Trade.SetTypeFillingBySymbol(_Symbol);
   Trade.SetDeviationInPoints(20);

   if(InpStepMode == STEP_ATR)
   {
      g_atrHandle = iATR(_Symbol, InpAtrTF, InpAtrPeriod);
      if(g_atrHandle == INVALID_HANDLE) { Print("ATR handle failed"); return INIT_FAILED; }
   }

   if(InpSTFilter != ST_FILTER_NONE)
   {
      ENUM_TIMEFRAMES tf = (InpSTFilter==ST_FILTER_HTF) ? InpSTTimeframe : _Period;
      //--- параметры передаём в порядке inputs индикатора EvasiveST_FBG.mq5.
      //    Если у тебя версия с другим порядком — при компиляции скажет.
      g_stHandle = iCustom(_Symbol, tf, InpSTIndicatorName,
                           InpST_AtrLength,
                           InpST_BaseMultiplier,
                           InpST_NoiseThreshold,
                           InpST_ExpansionAlpha,
                           InpST_EvasionPersist);
      if(g_stHandle == INVALID_HANDLE)
      {
         PrintFormat("ST indicator handle failed for '%s'. Filter disabled.", InpSTIndicatorName);
      }
   }

   g_attachEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_frozen = false;
   g_lastAddTime[0] = 0; g_lastAddTime[1] = 0;
   ResetTrail(POSITION_TYPE_BUY);
   ResetTrail(POSITION_TYPE_SELL);

   //--- handoff: парсим список магиков и публикуем стартовый Active
   ParseAdoptMagicsCSV(InpAdoptMagicsCSV);
   if(InpAdoptionMode == ADOPT_BY_MAGIC_LIST)
      PrintFormat("Adoption: BY_MAGIC_LIST, %d magics parsed from \"%s\"",
                  g_adoptMagicsCount, InpAdoptMagicsCSV);
   else if(InpAdoptionMode == ADOPT_ALL_FOREIGN)
      Print("Adoption: ALL foreign positions on this symbol.");
   else
      Print("Adoption: only own magic ", InpMagic, ".");

   HandoffPublishActive(false);

   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)
       == ACCOUNT_MARGIN_MODE_RETAIL_NETTING)
      Print("WARNING: netting account. Recovery EA assumes hedging; behaviour will be approximate.");

   EventSetTimer(InpTimerSec > 0 ? InpTimerSec : 2);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_stHandle  != INVALID_HANDLE) IndicatorRelease(g_stHandle);
   //--- handoff: снимаем флаг Active, чтобы Алиса не висла в halt
   HandoffPublishActive(false);
   Comment("");
}

void OnTick()  { Cycle(); }
void OnTimer() { Cycle(); }
//+------------------------------------------------------------------+
