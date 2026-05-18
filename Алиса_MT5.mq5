//+------------------------------------------------------------------+
//|                                                  Алиса_MT5.mq5   |
//|       Советник на основе Evasive SuperTrend + Ложный пробой      |
//|       Герчика. Вся логика индикатора встроена ВНУТРЬ EA          |
//|       (без iCustom и без внешних индикаторов).                   |
//|                                                                  |
//|  Возможности:                                                    |
//|   * Evasive SuperTrend: ATR Уайлдера/Кауфмана, расширение полосы |
//|     при заходе цены в шумовую зону.                              |
//|   * HTF-фильтр (СуперТренд на старшем ТФ).                       |
//|   * Сигнал Герчика: ложный пробой N-барного экстремума или       |
//|     вчерашнего D1 + проверка хвоста, тела, объёма, ретеста.      |
//|   * Анти-спам: кулдаун между сделками одного направления.        |
//|   * Управление позицией: SL за хвостом пробоя, TP по ATR,        |
//|     перевод в безубыток, трейлинг по линии СуперТренда.          |
//|   * Лотность: фикс / % риска от баланса по дистанции SL.         |
//|   * Один тикет на символ+магик; контроль спреда и часов работы.  |
//+------------------------------------------------------------------+
#property copyright   "Devin"
#property version     "1.00"
#property description "Алиса MT5: Evasive SuperTrend + Герчик (логика индикатора встроена в EA)"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/SymbolInfo.mqh>

CTrade         Trade;
CPositionInfo  Pos;
CSymbolInfo    Sym;

//================== Перечисления =====================================
enum ENUM_FBG_LEVEL_MODE
  {
   FBG_LEVEL_NBARS = 0,  // Экстремум за N баров
   FBG_LEVEL_DAILY = 1   // Вчерашний High/Low (D1)
  };

enum ENUM_LOT_MODE
  {
   LOT_FIXED   = 0,  // Фиксированный лот
   LOT_RISKPCT = 1   // Риск % от баланса (по дистанции SL)
  };

enum ENUM_SIGNAL_SOURCE
  {
   SIG_ST_FLIP = 0,  // Только флипы СуперТренда
   SIG_FBG     = 1,  // Только сигналы Герчика
   SIG_BOTH    = 2   // Оба источника
  };

//================== Входные параметры — стратегия ====================
input group "=== Источник сигналов ==="
input ENUM_SIGNAL_SOURCE InpSigSource     = SIG_FBG;     // Источник торговых сигналов
input bool               InpAllowLong     = true;        // Разрешить покупки
input bool               InpAllowShort    = true;        // Разрешить продажи

input group "=== Настройки СуперТренда ==="
input int                InpAtrLength      = 10;         // Длина ATR
input double             InpBaseMultiplier = 3.0;        // Базовый множитель

input group "=== Уход от шумовой зоны ==="
input double             InpNoiseThreshold = 1.0;        // Порог шума (xATR)
input double             InpExpansionAlpha = 0.5;        // Расширение (xATR)
input bool               InpEvasionPersist = true;       // Сохранять смещение ухода

input group "=== Адаптивный ATR (Кауфман) ==="
input bool               InpAdaptive       = false;      // Адаптивный ATR вместо Уайлдера
input int                InpAdaptiveMin    = 5;          // Быстрый эфф. период
input int                InpAdaptiveMax    = 30;         // Медленный эфф. период
input int                InpEfficiencyLen  = 10;         // Длина Efficiency Ratio

input group "=== Подтверждение по старшему ТФ ==="
input bool               InpUseHTF         = false;      // Фильтр по старшему ТФ
input ENUM_TIMEFRAMES    InpHTF            = PERIOD_H1;  // Старший таймфрейм
input int                InpHtfAtrPeriod   = 10;         // ATR на старшем ТФ
input double             InpHtfMultiplier  = 3.0;        // Множитель ATR на ст. ТФ
input bool               InpHtfFailOpen    = true;       // При недоступном HTF — пропускать

input group "=== Ложный пробой по Герчику ==="
input bool               InpFBGEnabled     = true;       // Включить сигналы Герчика
input ENUM_FBG_LEVEL_MODE InpFBGLevelMode  = FBG_LEVEL_NBARS; // Источник уровня
input int                InpFBGLookback    = 20;         // Окно N (для режима N баров)
input double             InpFBGMinTailATR  = 0.15;       // Мин. хвост пробоя (xATR)
input double             InpFBGMaxBodyATR  = 1.50;       // Макс. тело бара (xATR; 0 — выкл.)
input bool               InpOnlyWithTrend  = true;       // Сигналы Герчика только по тренду ST

input group "=== v2.04: фильтры FBG ==="
input int                InpFBGCooldownBars = 3;         // Кулдаун между сделками одной стороны
input bool               InpFBGUseVolume   = false;      // Объёмный фильтр пробоя
input double             InpFBGMinVolMult  = 1.5;        // Мин. множитель к ср. объёму
input bool               InpFBGRequireRetest = false;    // Требовать ретест уровня
input int                InpFBGRetestBars    = 5;        // Окно ретеста (баров)

//================== Входные параметры — торговля =====================
input group "=== Лот и риск ==="
input ENUM_LOT_MODE      InpLotMode        = LOT_FIXED;  // Способ задания лота
input double             InpFixedLot       = 0.10;       // Фиксированный лот
input double             InpRiskPct        = 1.0;        // Риск (% баланса) на сделку
input double             InpMaxLot         = 10.0;       // Жёсткий потолок лота

input group "=== SL / TP ==="
input double             InpSLBufferATR    = 0.25;       // Буфер SL за хвостом (xATR)
input double             InpTPATR          = 2.0;        // TP в ATR от входа (0 — без TP)
input double             InpFallbackSLATR  = 1.5;        // SL для ST-флипа (xATR)
input bool               InpUseBreakeven   = true;       // Перевод в безубыток
input double             InpBE_TriggerATR  = 1.0;        // Триггер БУ (прибыль в ATR)
input double             InpBE_OffsetATR   = 0.10;       // Смещение БУ от входа (xATR)
input bool               InpUseTrailST     = true;       // Трейлинг по линии СуперТренда
input double             InpTrailSTBufATR  = 0.20;       // Буфер трейлинга (xATR)

input group "=== Управление сделками ==="
input ulong              InpMagic          = 20260518;   // Магик-номер
input int                InpDeviationPts   = 20;         // Допустимый слиппедж (пункты)
input int                InpMaxSpreadPts   = 30;         // Макс. спред (пункты, 0 — выкл.)
input bool               InpOneAtATime     = true;       // Не более одной позиции (символ+магик)
input bool               InpCloseOpposite  = true;       // На противоположном сигнале — закрыть
input string             InpComment        = "Алиса";    // Комментарий к ордерам

input group "=== Время работы (час сервера) ==="
input bool               InpUseTimeFilter  = false;      // Фильтр часов торговли
input int                InpHourStart      = 8;          // Час начала (включительно)
input int                InpHourEnd        = 22;         // Час конца (НЕвключительно)

input group "=== История / прочее ==="
input int                InpHistoryBars    = 2000;       // Глубина истории для расчёта
input bool               InpLogToTerminal  = true;       // Печатать события в журнал

//================== Состояние ========================================
//--- расчётные массивы (индексация как timeseries=false: [0]=oldest)
double      g_atr[];        // ATR на каждом баре локального ТФ
int         g_trend[];      // 1 / -1
double      g_stLine[];     // линия ST для трейлинга
bool        g_evas[];       // флаг ухода
double      g_fu[];         // финальная верхняя
double      g_fl[];         // финальная нижняя

//--- кэш HTF SuperTrend
struct HTFTrendBar { datetime time; int trend; double st; };
HTFTrendBar g_htf[];
datetime    g_htfLastUpdate = 0;
int         g_htfCursor     = 0;

//--- скользящее окно ER (для адаптивного ATR)
double      g_erVol[];

//--- бар-контроль и анти-дубликат
datetime    g_lastBarTime    = 0;
datetime    g_lastTradeBar   = 0;
int         g_lastBuyIdx     = -1;
int         g_lastSellIdx    = -1;

//--- ожидающие ретест сигналы FBG
struct FBGPending
  {
   bool     active;
   int      sigBar;
   double   level;
   double   tail;
   double   atrAtSig;
  };
FBGPending  g_pendingBuy;
FBGPending  g_pendingSell;

//+------------------------------------------------------------------+
//| Утилиты                                                          |
//+------------------------------------------------------------------+
double PipSize()
  {
   int d = (int)_Digits;
   if(d == 3 || d == 5) return _Point * 10.0;
   return _Point;
  }

string TfLabel(const ENUM_TIMEFRAMES tf)
  {
   string s = EnumToString(tf);
   int p = StringFind(s, "PERIOD_");
   if(p == 0) s = StringSubstr(s, 7);
   return s;
  }

double TrueRange(const double h, const double l, const double pc)
  {
   return MathMax(h - l, MathMax(MathAbs(h - pc), MathAbs(l - pc)));
  }

void Log(const string msg)
  {
   if(InpLogToTerminal) Print("[Алиса] ", msg);
  }

//+------------------------------------------------------------------+
//| Скользящий Efficiency Ratio (для адаптивного ATR)                |
//+------------------------------------------------------------------+
double ERFast(const double &close[], const int i, const int n)
  {
   if(i < n) return 0.0;
   double vol;
   if(i == n)
     {
      double s = 0.0;
      for(int k = 1; k <= n; ++k) s += MathAbs(close[k] - close[k - 1]);
      vol = s;
     }
   else
     {
      double dropped = MathAbs(close[i - n] - close[i - n - 1]);
      double added   = MathAbs(close[i]     - close[i - 1]);
      vol = g_erVol[i - 1] + added - dropped;
      if(vol < 0.0) vol = 0.0;
     }
   g_erVol[i] = vol;
   double change = MathAbs(close[i] - close[i - n]);
   return (vol > 0.0) ? change / vol : 0.0;
  }

//+------------------------------------------------------------------+
//| Расчёт ATR для локального ТФ                                     |
//+------------------------------------------------------------------+
void ComputeATR(const int n,
                const double &high[], const double &low[], const double &close[])
  {
   if(ArraySize(g_atr) != n) ArrayResize(g_atr, n);
   if(InpAdaptive && ArraySize(g_erVol) != n) ArrayResize(g_erVol, n);
   if(n <= 1) { ArrayInitialize(g_atr, 0.0); return; }
   g_atr[0] = 0.0;

   if(InpAdaptive)
     {
      double fast = 2.0 / (InpAdaptiveMin + 1.0);
      double slow = 2.0 / (InpAdaptiveMax + 1.0);
      double prev = TrueRange(high[1], low[1], close[0]);
      g_atr[1] = prev;
      for(int i = 2; i < n; ++i)
        {
         double tr = TrueRange(high[i], low[i], close[i - 1]);
         double er = ERFast(close, i, InpEfficiencyLen);
         double sc = MathPow(er * (fast - slow) + slow, 2.0);
         prev = prev + sc * (tr - prev);
         g_atr[i] = prev;
        }
     }
   else
     {
      int p = (InpAtrLength < 1) ? 1 : InpAtrLength;
      double sum = 0.0;
      int seedEnd = MathMin(n - 1, p);
      for(int i = 1; i <= seedEnd; ++i)
        {
         sum += TrueRange(high[i], low[i], close[i - 1]);
         g_atr[i] = sum / i;
        }
      for(int i = p + 1; i < n; ++i)
        {
         double tr = TrueRange(high[i], low[i], close[i - 1]);
         g_atr[i] = (g_atr[i - 1] * (p - 1) + tr) / p;
        }
     }
  }

//+------------------------------------------------------------------+
//| Расчёт SuperTrend (Evasive) на локальном ТФ                      |
//+------------------------------------------------------------------+
void ComputeSuperTrend(const int n,
                       const double &high[], const double &low[],
                       const double &close[])
  {
   if(ArraySize(g_trend)  != n) ArrayResize(g_trend,  n);
   if(ArraySize(g_stLine) != n) ArrayResize(g_stLine, n);
   if(ArraySize(g_evas)   != n) ArrayResize(g_evas,   n);
   if(ArraySize(g_fu)     != n) ArrayResize(g_fu,     n);
   if(ArraySize(g_fl)     != n) ArrayResize(g_fl,     n);

   g_trend[0]  = 1;
   g_stLine[0] = 0.0;
   g_evas[0]   = false;
   g_fu[0]     = 0.0;
   g_fl[0]     = 0.0;

   for(int i = 1; i < n; ++i)
     {
      double atr = g_atr[i];
      double hl2 = (high[i] + low[i]) * 0.5;
      double bu  = hl2 + InpBaseMultiplier * atr;
      double bl  = hl2 - InpBaseMultiplier * atr;
      double pu  = g_fu[i - 1];
      double pl  = g_fl[i - 1];
      double pc  = close[i - 1];

      double fuRaw = (bu < pu || pc > pu) ? bu : pu;
      double flRaw = (bl > pl || pc < pl) ? bl : pl;
      double fu = fuRaw, fl = flRaw;

      int prevTrend = g_trend[i - 1];
      if(prevTrend == 0) prevTrend = 1;
      int trend = (prevTrend == 1) ? ((close[i] < fl) ? -1 :  1)
                                   : ((close[i] > fu) ?  1 : -1);

      bool   evas    = false;
      double noise   = InpNoiseThreshold * atr;
      double expand  = InpExpansionAlpha * atr;
      double stValue;
      if(trend == 1)
        {
         double dist = close[i] - fl;
         if(dist < noise && atr > 0.0) { fl -= expand; evas = true; }
         stValue = fl;
        }
      else
        {
         double dist = fu - close[i];
         if(dist < noise && atr > 0.0) { fu += expand; evas = true; }
         stValue = fu;
        }

      if(InpEvasionPersist) { g_fu[i] = fu;    g_fl[i] = fl;    }
      else                  { g_fu[i] = fuRaw; g_fl[i] = flRaw; }

      g_trend[i]  = trend;
      g_evas[i]   = evas;
      g_stLine[i] = stValue;
     }
  }

//+------------------------------------------------------------------+
//| HTF SuperTrend: пересборка кэша                                  |
//+------------------------------------------------------------------+
void RebuildHTFTrend()
  {
   if(!InpUseHTF) { ArrayResize(g_htf, 0); return; }
   datetime lastHTFBar =
      (datetime)SeriesInfoInteger(_Symbol, InpHTF, SERIES_LASTBAR_DATE);
   if(lastHTFBar == g_htfLastUpdate && ArraySize(g_htf) > 0) return;

   int bars = Bars(_Symbol, InpHTF);
   if(bars < 5) return;
   int want = MathMin(bars, MathMax(InpHistoryBars, 1500));
   MqlRates r[];
   int copied = CopyRates(_Symbol, InpHTF, 0, want, r);
   if(copied < 5) return;

   ArrayResize(g_htf, copied);
   int    p   = (InpHtfAtrPeriod < 1) ? 1 : InpHtfAtrPeriod;
   double atr = 0.0, prevUpper = 0.0, prevLower = 0.0;
   double sumTr = 0.0;
   int    trend = 1;

   g_htf[0].time = r[0].time;
   g_htf[0].trend = trend;
   g_htf[0].st    = 0.0;

   for(int i = 1; i < copied; ++i)
     {
      g_htf[i].time = r[i].time;
      double tr = TrueRange(r[i].high, r[i].low, r[i - 1].close);

      if(i <= p)
        {
         sumTr += tr;
         atr   = sumTr / i;
        }
      else
         atr = (atr * (p - 1.0) + tr) / p;

      double hl2 = (r[i].high + r[i].low) * 0.5;
      double bu  = hl2 + InpHtfMultiplier * atr;
      double bl  = hl2 - InpHtfMultiplier * atr;
      double fu  = (bu < prevUpper || r[i - 1].close > prevUpper) ? bu : prevUpper;
      double fl  = (bl > prevLower || r[i - 1].close < prevLower) ? bl : prevLower;

      if(trend == 1) trend = (r[i].close < fl) ? -1 :  1;
      else           trend = (r[i].close > fu) ?  1 : -1;

      g_htf[i].trend = trend;
      g_htf[i].st    = (trend == 1) ? fl : fu;
      prevUpper = fu; prevLower = fl;
     }

   g_htfLastUpdate = lastHTFBar;
   g_htfCursor = 0;
  }

int HTFTrendAt(const datetime t)
  {
   int n = ArraySize(g_htf);
   if(n == 0) return 0;
   int idx = g_htfCursor;
   if(idx >= n) idx = n - 1;
   if(idx < 0)  idx = 0;
   if(g_htf[idx].time <= t)
     {
      while(idx + 1 < n && g_htf[idx + 1].time <= t) ++idx;
      g_htfCursor = idx;
      return g_htf[idx].trend;
     }
   if(idx > 0 && g_htf[idx - 1].time <= t)
     {
      g_htfCursor = idx - 1;
      return g_htf[idx - 1].trend;
     }
   int lo = 0, hi = n - 1, ans = -1;
   while(lo <= hi)
     {
      int mid = (lo + hi) >> 1;
      if(g_htf[mid].time <= t) { ans = mid; lo = mid + 1; }
      else hi = mid - 1;
     }
   if(ans < 0) return 0;
   g_htfCursor = ans;
   return g_htf[ans].trend;
  }

bool HTFAllows(const datetime t, const int side)
  {
   if(!InpUseHTF) return true;
   int htf = HTFTrendAt(t);
   if(htf == 0) return InpHtfFailOpen;
   return (side == 1) ? (htf >= 0) : (htf <= 0);
  }

//+------------------------------------------------------------------+
//| Уровни Герчика на индексе i (0 = старейший)                      |
//+------------------------------------------------------------------+
bool GetFBGLevels(const int i, const datetime &time[],
                  const double &high[], const double &low[],
                  double &outHigh, double &outLow)
  {
   outHigh = 0.0; outLow = 0.0;
   if(InpFBGLevelMode == FBG_LEVEL_NBARS)
     {
      if(i - InpFBGLookback < 0) return false;
      double hh = high[i - 1];
      double ll = low[i - 1];
      for(int k = 2; k <= InpFBGLookback; ++k)
        {
         int idx = i - k;
         if(idx < 0) return false;
         if(high[idx] > hh) hh = high[idx];
         if(low[idx]  < ll) ll = low[idx];
        }
      outHigh = hh; outLow = ll;
      return true;
     }
   // FBG_LEVEL_DAILY
   MqlDateTime sdt;
   TimeToStruct(time[i], sdt);
   sdt.hour = 0; sdt.min = 0; sdt.sec = 0;
   datetime curDayStart = StructToTime(sdt);
   datetime prevDayTime = curDayStart - 60;
   int shift = iBarShift(_Symbol, PERIOD_D1, prevDayTime, false);
   if(shift < 0) return false;
   double yH = iHigh(_Symbol, PERIOD_D1, shift);
   double yL = iLow(_Symbol,  PERIOD_D1, shift);
   if(yH <= 0.0 || yL <= 0.0) return false;
   outHigh = yH; outLow = yL;
   return true;
  }

double AvgTickVolume(const int i, const long &tick_volume[], const int n)
  {
   if(n <= 0 || i - n < 0) return 0.0;
   double s = 0.0;
   for(int k = 1; k <= n; ++k) s += (double)tick_volume[i - k];
   return s / n;
  }

//+------------------------------------------------------------------+
//| Структура сигнала                                                |
//+------------------------------------------------------------------+
struct SignalInfo
  {
   int      side;     // +1 BUY, -1 SELL, 0 нет
   string   reason;   // "ST_FLIP" / "FBG" / "FBG_RETEST"
   double   level;    // пробитый уровень (для SL); 0 если не применимо
   double   tail;     // длина хвоста пробоя
   double   atr;      // ATR на баре сигнала
   datetime barTime;  // время бара сигнала
  };

//+------------------------------------------------------------------+
//| Поиск сигнала на закрытом баре с индексом sigIdx (0=старейший).  |
//+------------------------------------------------------------------+
bool FindSignalOnBar(const int sigIdx,
                     const int n,
                     const datetime &time[], const double &open[],
                     const double &high[],   const double &low[],
                     const double &close[],  const long &tick_volume[],
                     SignalInfo &out)
  {
   out.side = 0; out.reason = ""; out.level = 0.0;
   out.tail = 0.0; out.atr = 0.0; out.barTime = 0;

   if(sigIdx < 2 || sigIdx >= n) return false;

   int    trend   = g_trend[sigIdx];
   int    prevTrn = g_trend[sigIdx - 1];
   double atr     = g_atr[sigIdx];
   datetime t     = time[sigIdx];

   //--- 1) Флип СуперТренда
   if((InpSigSource == SIG_ST_FLIP || InpSigSource == SIG_BOTH)
      && trend != prevTrn && atr > 0.0)
     {
      int side = trend; // +1 / -1
      if(HTFAllows(t, side))
        {
         out.side    = side;
         out.reason  = "ST_FLIP";
         out.level   = 0.0;
         out.tail    = 0.0;
         out.atr     = atr;
         out.barTime = t;
         return true;
        }
     }

   //--- 2) Сигнал Герчика
   if(!InpFBGEnabled) return false;
   if(InpSigSource == SIG_ST_FLIP) return false;

   double lh, ll;
   if(!GetFBGLevels(sigIdx, time, high, low, lh, ll))
     {
      // pending по таймауту
      if(InpFBGRequireRetest)
        {
         if(g_pendingBuy.active  && sigIdx - g_pendingBuy.sigBar  > InpFBGRetestBars) g_pendingBuy.active  = false;
         if(g_pendingSell.active && sigIdx - g_pendingSell.sigBar > InpFBGRetestBars) g_pendingSell.active = false;
        }
      return false;
     }

   double body = MathAbs(close[sigIdx] - open[sigIdx]);
   double mid  = (high[sigIdx] + low[sigIdx]) * 0.5;

   bool isSell = false, isBuy = false;
   double sellTail = 0.0, buyTail = 0.0;

   if(lh > 0.0 && high[sigIdx] > lh && close[sigIdx] < lh && close[sigIdx] < mid)
     {
      sellTail = high[sigIdx] - lh;
      if(InpFBGMinTailATR <= 0.0 || atr <= 0.0 || sellTail >= atr * InpFBGMinTailATR)
         isSell = true;
     }
   if(ll > 0.0 && low[sigIdx] < ll && close[sigIdx] > ll && close[sigIdx] > mid)
     {
      buyTail = ll - low[sigIdx];
      if(InpFBGMinTailATR <= 0.0 || atr <= 0.0 || buyTail >= atr * InpFBGMinTailATR)
         isBuy = true;
     }

   //--- ретест pending BUY
   if(InpFBGRequireRetest && g_pendingBuy.active)
     {
      if(sigIdx - g_pendingBuy.sigBar > InpFBGRetestBars)
         g_pendingBuy.active = false;
      else if(sigIdx > g_pendingBuy.sigBar)
        {
         bool touched     = (low[sigIdx]   <= g_pendingBuy.level);
         bool closedAbove = (close[sigIdx] >  g_pendingBuy.level);
         if(touched && closedAbove)
           {
            out.side    = +1;
            out.reason  = "FBG_RETEST";
            out.level   = g_pendingBuy.level;
            out.tail    = g_pendingBuy.tail;
            out.atr     = g_pendingBuy.atrAtSig;
            out.barTime = t;
            g_pendingBuy.active = false;
            return true;
           }
        }
     }
   if(InpFBGRequireRetest && g_pendingSell.active)
     {
      if(sigIdx - g_pendingSell.sigBar > InpFBGRetestBars)
         g_pendingSell.active = false;
      else if(sigIdx > g_pendingSell.sigBar)
        {
         bool touched     = (high[sigIdx]  >= g_pendingSell.level);
         bool closedBelow = (close[sigIdx] <  g_pendingSell.level);
         if(touched && closedBelow)
           {
            out.side    = -1;
            out.reason  = "FBG_RETEST";
            out.level   = g_pendingSell.level;
            out.tail    = g_pendingSell.tail;
            out.atr     = g_pendingSell.atrAtSig;
            out.barTime = t;
            g_pendingSell.active = false;
            return true;
           }
        }
     }

   if(!isSell && !isBuy) return false;

   //--- объёмный фильтр
   if(InpFBGUseVolume && InpFBGMinVolMult > 0.0)
     {
      double avgV = AvgTickVolume(sigIdx, tick_volume, InpFBGLookback);
      if(avgV > 0.0)
        {
         double curV = (double)tick_volume[sigIdx];
         if(curV < avgV * InpFBGMinVolMult) return false;
        }
     }

   //--- импульсный фильтр (большое тело)
   bool bodyOk = !(InpFBGMaxBodyATR > 0.0 && atr > 0.0
                   && body > atr * InpFBGMaxBodyATR);
   if(!bodyOk) return false;

   int  side      = isBuy ? +1 : -1;
   bool ltfAgree  = (side == trend);
   bool htfAgree  = HTFAllows(t, side);
   bool withTrend = ltfAgree && htfAgree;

   if(InpOnlyWithTrend && !withTrend) return false;
   if(!withTrend && !InpOnlyWithTrend && !htfAgree)
      return false; // HTF режет встречку всегда

   if(InpFBGRequireRetest)
     {
      // только заносим в pending — стрелка/сигнал на ретесте
      FBGPending pend;
      pend.active   = true;
      pend.sigBar   = sigIdx;
      pend.level    = isBuy ? ll : lh;
      pend.tail     = isBuy ? buyTail : sellTail;
      pend.atrAtSig = atr;
      if(isBuy) g_pendingBuy = pend;
      else      g_pendingSell = pend;
      return false;
     }

   out.side    = side;
   out.reason  = "FBG";
   out.level   = isBuy ? ll : lh;
   out.tail    = isBuy ? buyTail : sellTail;
   out.atr     = atr;
   out.barTime = t;
   return true;
  }

//+------------------------------------------------------------------+
//| Кулдаун на сделки одной стороны                                  |
//+------------------------------------------------------------------+
bool CooldownAllows(const int sigIdx, const int side)
  {
   if(InpFBGCooldownBars <= 0) return true;
   int last = (side == 1) ? g_lastBuyIdx : g_lastSellIdx;
   if(last < 0) return true;
   return (sigIdx - last > InpFBGCooldownBars);
  }

//+------------------------------------------------------------------+
//| Расчёт цены SL/TP по сигналу                                     |
//+------------------------------------------------------------------+
void ComputeSLTP(const SignalInfo &sig, const double entry,
                 double &sl, double &tp)
  {
   sl = 0.0; tp = 0.0;
   double atr = sig.atr;
   if(atr <= 0.0) return;

   if(sig.reason == "FBG" || sig.reason == "FBG_RETEST")
     {
      if(sig.side == 1)
        {
         sl = sig.level - sig.tail - atr * InpSLBufferATR;
         if(InpTPATR > 0.0) tp = entry + atr * InpTPATR;
        }
      else
        {
         sl = sig.level + sig.tail + atr * InpSLBufferATR;
         if(InpTPATR > 0.0) tp = entry - atr * InpTPATR;
        }
     }
   else // ST_FLIP — нет уровня; берём ATR-стоп
     {
      double slDist = atr * InpFallbackSLATR;
      if(sig.side == 1)
        {
         sl = entry - slDist;
         if(InpTPATR > 0.0) tp = entry + atr * InpTPATR;
        }
      else
        {
         sl = entry + slDist;
         if(InpTPATR > 0.0) tp = entry - atr * InpTPATR;
        }
     }
  }

//+------------------------------------------------------------------+
//| Размер лота                                                      |
//+------------------------------------------------------------------+
double NormalizeVolume(double v)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0) step = 0.01;
   v = MathFloor(v / step) * step;
   if(v < vmin) v = vmin;
   if(v > vmax) v = vmax;
   if(v > InpMaxLot) v = InpMaxLot;
   // округление до того же количества знаков, что и step
   int digits = 0;
   double s = step;
   while(s < 1.0 && digits < 8) { s *= 10.0; digits++; }
   return NormalizeDouble(v, digits);
  }

double ComputeLot(const double entry, const double sl)
  {
   if(InpLotMode == LOT_FIXED) return NormalizeVolume(InpFixedLot);

   double slDist = MathAbs(entry - sl);
   if(slDist <= 0.0) return NormalizeVolume(InpFixedLot);

   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0) return NormalizeVolume(InpFixedLot);

   double lossPerLot = (slDist / tickSize) * tickValue;
   if(lossPerLot <= 0.0) return NormalizeVolume(InpFixedLot);

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk    = balance * (InpRiskPct / 100.0);
   double lot     = risk / lossPerLot;
   return NormalizeVolume(lot);
  }

//+------------------------------------------------------------------+
//| Текущая позиция этого EA на этом символе                         |
//+------------------------------------------------------------------+
bool HasOurPosition(int &out_type)
  {
   out_type = -1;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      if(!Pos.SelectByIndex(i)) continue;
      if(Pos.Symbol() != _Symbol) continue;
      if(Pos.Magic()  != InpMagic) continue;
      out_type = (int)Pos.PositionType();
      return true;
     }
   return false;
  }

bool CloseOurPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      if(!Pos.SelectByIndex(i)) continue;
      if(Pos.Symbol() != _Symbol) continue;
      if(Pos.Magic()  != InpMagic) continue;
      ulong ticket = Pos.Ticket();
      if(!Trade.PositionClose(ticket))
        {
         Log(StringFormat("Не удалось закрыть позицию #%I64u err=%d",
                          ticket, GetLastError()));
         return false;
        }
      Log(StringFormat("Закрыта позиция #%I64u", ticket));
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Контроль спреда / часов работы                                   |
//+------------------------------------------------------------------+
bool TradingHourOk(const datetime t)
  {
   if(!InpUseTimeFilter) return true;
   MqlDateTime sdt; TimeToStruct(t, sdt);
   if(InpHourStart == InpHourEnd) return true;
   if(InpHourStart < InpHourEnd)
      return (sdt.hour >= InpHourStart && sdt.hour < InpHourEnd);
   // переход через полночь
   return (sdt.hour >= InpHourStart || sdt.hour < InpHourEnd);
  }

bool SpreadOk()
  {
   if(InpMaxSpreadPts <= 0) return true;
   long sp = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double pip = PipSize();
   double spreadPts = (double)sp * _Point / pip; // в «трейдерских» пунктах
   return spreadPts <= (double)InpMaxSpreadPts;
  }

//+------------------------------------------------------------------+
//| Открытие сделки по сигналу                                       |
//+------------------------------------------------------------------+
void TryOpen(const SignalInfo &sig, const double bid, const double ask)
  {
   if(sig.side ==  1 && !InpAllowLong)  return;
   if(sig.side == -1 && !InpAllowShort) return;

   double entry = (sig.side == 1) ? ask : bid;
   double sl, tp;
   ComputeSLTP(sig, entry, sl, tp);

   if(sl <= 0.0)
     {
      Log("Не удалось вычислить SL — сигнал пропущен");
      return;
     }

   //--- проверка минимальной дистанции стопа
   long stopLevelPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = (double)stopLevelPts * _Point;
   if(MathAbs(entry - sl) < minDist + _Point)
     {
      // расширим SL до минимально допустимого
      sl = (sig.side == 1) ? entry - (minDist + _Point)
                           : entry + (minDist + _Point);
     }
   if(tp != 0.0 && MathAbs(entry - tp) < minDist + _Point)
     {
      tp = (sig.side == 1) ? entry + (minDist + _Point)
                           : entry - (minDist + _Point);
     }

   double lot = ComputeLot(entry, sl);
   if(lot <= 0.0) { Log("Лот <= 0, пропуск"); return; }

   sl = NormalizeDouble(sl, _Digits);
   tp = (tp == 0.0) ? 0.0 : NormalizeDouble(tp, _Digits);

   bool ok;
   string cmt = StringFormat("%s %s", InpComment, sig.reason);
   if(sig.side == 1) ok = Trade.Buy (lot, _Symbol, 0.0, sl, tp, cmt);
   else              ok = Trade.Sell(lot, _Symbol, 0.0, sl, tp, cmt);

   if(ok)
     {
      Log(StringFormat("OPEN %s lot=%.2f sl=%s tp=%s reason=%s",
                       (sig.side == 1) ? "BUY" : "SELL",
                       lot,
                       DoubleToString(sl, _Digits),
                       (tp == 0.0) ? "—" : DoubleToString(tp, _Digits),
                       sig.reason));
     }
   else
     {
      Log(StringFormat("Ошибка открытия %s err=%d retcode=%u",
                       (sig.side == 1) ? "BUY" : "SELL",
                       GetLastError(), Trade.ResultRetcode()));
     }
  }

//+------------------------------------------------------------------+
//| Сопровождение позиции: безубыток + трейлинг по линии ST          |
//+------------------------------------------------------------------+
void ManagePosition(const double atr, const double stLine, const int trend)
  {
   if(!Pos.Select(_Symbol)) return;
   if(Pos.Magic() != InpMagic) return;

   double entry  = Pos.PriceOpen();
   double curSL  = Pos.StopLoss();
   double curTP  = Pos.TakeProfit();
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   long   type   = Pos.PositionType();
   double newSL  = curSL;

   //--- безубыток
   if(InpUseBreakeven && atr > 0.0)
     {
      double trigger = atr * InpBE_TriggerATR;
      double offset  = atr * InpBE_OffsetATR;
      if(type == POSITION_TYPE_BUY)
        {
         if(bid - entry >= trigger)
           {
            double be = entry + offset;
            if(curSL < be) newSL = be;
           }
        }
      else
        {
         if(entry - ask >= trigger)
           {
            double be = entry - offset;
            if(curSL == 0.0 || curSL > be) newSL = be;
           }
        }
     }

   //--- трейлинг по линии СуперТренда
   if(InpUseTrailST && stLine > 0.0 && atr > 0.0)
     {
      double buf = atr * InpTrailSTBufATR;
      if(type == POSITION_TYPE_BUY && trend == 1)
        {
         double cand = stLine - buf;
         if(cand > newSL && cand < bid) newSL = cand;
        }
      else if(type == POSITION_TYPE_SELL && trend == -1)
        {
         double cand = stLine + buf;
         if((newSL == 0.0 || cand < newSL) && cand > ask) newSL = cand;
        }
     }

   if(MathAbs(newSL - curSL) >= _Point && newSL != 0.0)
     {
      // соблюдаем StopLevel
      long stopLevelPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double minDist = (double)stopLevelPts * _Point;
      double ref = (type == POSITION_TYPE_BUY) ? bid : ask;
      bool farEnough = (type == POSITION_TYPE_BUY) ? (ref - newSL >= minDist)
                                                   : (newSL - ref >= minDist);
      if(farEnough)
        {
         newSL = NormalizeDouble(newSL, _Digits);
         if(!Trade.PositionModify(_Symbol, newSL, curTP))
            Log(StringFormat("Не удалось модифицировать SL: err=%d retcode=%u",
                             GetLastError(), Trade.ResultRetcode()));
        }
     }
  }

//+------------------------------------------------------------------+
//| OnInit / OnDeinit                                                |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!Sym.Name(_Symbol)) Sym.Name(_Symbol);
   Sym.Refresh();

   Trade.SetExpertMagicNumber(InpMagic);
   Trade.SetDeviationInPoints((ulong)InpDeviationPts);
   Trade.SetTypeFillingBySymbol(_Symbol);
   Trade.SetMarginMode();
   Trade.LogLevel(LOG_LEVEL_ERRORS);

   g_lastBarTime  = 0;
   g_lastTradeBar = 0;
   g_lastBuyIdx   = -1;
   g_lastSellIdx  = -1;
   g_pendingBuy.active  = false;
   g_pendingSell.active = false;
   g_htfLastUpdate = 0;
   g_htfCursor = 0;

   Log(StringFormat("Запуск на %s %s | источник=%s | HTF=%s",
       _Symbol, TfLabel((ENUM_TIMEFRAMES)_Period),
       EnumToString(InpSigSource),
       InpUseHTF ? TfLabel(InpHTF) : "выкл"));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   ArrayFree(g_atr);
   ArrayFree(g_trend);
   ArrayFree(g_stLine);
   ArrayFree(g_evas);
   ArrayFree(g_fu);
   ArrayFree(g_fl);
   ArrayFree(g_htf);
   ArrayFree(g_erVol);
  }

//+------------------------------------------------------------------+
//| Главный цикл                                                     |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- проверяем приход нового бара (работаем только на закрытии)
   datetime curBar = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);
   bool newBar = (curBar != g_lastBarTime);

   //--- забираем историю
   int want = MathMax(InpHistoryBars, MathMax(InpFBGLookback * 5, InpAtrLength * 10));
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int n = CopyRates(_Symbol, _Period, 0, want, r);
   if(n < 50) return;

   //--- разворачиваем в плоские массивы (timeseries=false: [0]=oldest)
   double op[], hi[], lo[], cl[];
   long   tv[];
   datetime tm[];
   ArrayResize(op, n); ArrayResize(hi, n); ArrayResize(lo, n);
   ArrayResize(cl, n); ArrayResize(tv, n); ArrayResize(tm, n);
   for(int i = 0; i < n; ++i)
     {
      op[i] = r[i].open;  hi[i] = r[i].high;  lo[i] = r[i].low;
      cl[i] = r[i].close; tv[i] = r[i].tick_volume; tm[i] = r[i].time;
     }

   //--- индикаторные расчёты
   ComputeATR(n, hi, lo, cl);
   ComputeSuperTrend(n, hi, lo, cl);
   RebuildHTFTrend();

   //--- сопровождение текущей позиции (на каждом тике)
   int lastIdx = n - 1;
   ManagePosition(g_atr[lastIdx], g_stLine[lastIdx], g_trend[lastIdx]);

   if(!newBar) return;

   //--- закрылся бар [n-2], новый сформированный бар = [n-1]
   g_lastBarTime = curBar;
   int sigIdx = n - 2;
   if(sigIdx < 5) return;

   //--- защита от двойного входа на одном баре
   if(tm[sigIdx] == g_lastTradeBar) return;

   //--- ищем сигнал на закрывшемся баре
   SignalInfo sig;
   if(!FindSignalOnBar(sigIdx, n, tm, op, hi, lo, cl, tv, sig))
      return;
   if(sig.side == 0) return;

   //--- кулдаун
   if(!CooldownAllows(sigIdx, sig.side)) return;

   //--- фильтры выхода на рынок
   if(!TradingHourOk(tm[sigIdx]))
     {
      Log("Сигнал вне окна торговых часов — пропуск");
      return;
     }
   if(!SpreadOk())
     {
      Log("Спред выше лимита — пропуск");
      return;
     }

   //--- работа с уже открытой позицией
   int posType;
   bool hasPos = HasOurPosition(posType);
   if(hasPos)
     {
      bool same = (posType == POSITION_TYPE_BUY  && sig.side == 1) ||
                  (posType == POSITION_TYPE_SELL && sig.side == -1);
      if(same) return; // уже в рынке в нужную сторону
      if(InpCloseOpposite)
        {
         CloseOurPosition();
         if(InpOneAtATime)
           {
            // закрыли — на этом же баре открываемся в обратку
           }
         else
            return;
        }
      else
         return;
     }
   else if(InpOneAtATime && PositionsTotal() > 0)
     {
      // если стоит «одна позиция» и есть позы под другим магиком — пропустим
      // (мы уже выяснили, что нашей позы нет, чужие не трогаем)
     }

   //--- цены входа
   Sym.RefreshRates();
   double bid = Sym.Bid();
   double ask = Sym.Ask();
   if(bid <= 0.0 || ask <= 0.0) return;

   TryOpen(sig, bid, ask);

   //--- учёт направления и времени входа (для кулдауна / анти-дубля)
   if(sig.side == 1) g_lastBuyIdx  = sigIdx;
   else              g_lastSellIdx = sigIdx;
   g_lastTradeBar = tm[sigIdx];
  }
//+------------------------------------------------------------------+
