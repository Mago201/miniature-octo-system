//+------------------------------------------------------------------+
//|                                            DrawdownRescue.mq5    |
//|         Универсальный советник для вытаскивания счёта из         |
//|         просадки. Подходит для любого инструмента MT5.           |
//|                                                                  |
//|  ВНИМАНИЕ. Любая стратегия "спасения" использует усреднение      |
//|  и/или сетку. Это математически означает увеличение риска при    |
//|  движении против вас. Этот советник не гарантирует прибыль и    |
//|  может слить депозит при сильном тренде против позиции.          |
//|  Используйте на демо-счёте, ставьте Equity-Stop и не отключайте  |
//|  предохранители.                                                 |
//|                                                                  |
//|  Возможности:                                                    |
//|   * Универсальность по активам: шаг сетки в ATR, авто-нормали-   |
//|     зация лота, поддержка 3/5-знаков, минимальные/макс. шаги     |
//|     в пунктах трейдера, контроль стоп-уровня брокера.            |
//|   * Усреднение: фикс / линейное / геометрическое / Фибоначчи.    |
//|   * TP корзины: % от депозита, пункты или деньги.                |
//|   * Триггер просадки: режим спасения активируется только         |
//|     при просадке >= заданного %.                                 |
//|   * Управление ручными сделками (флаг InpManageManualTrades).    |
//|   * Защита счёта: Equity-Stop %, дневной лимит потерь, пятница,  |
//|     максимальный совокупный лот, лимит числа усреднений,         |
//|     фильтр спреда, минимальное расстояние до уровней брокера.    |
//|   * Авто-первый вход по EMA-тренду или ручной режим.             |
//|   * Брэйк-ивен после N усреднений (опционально).                 |
//|                                                                  |
//|  v1.00 — первая версия.                                          |
//|  v1.10 — три новых блока:                                        |
//|   * Хедж-лок: при достижении просадки открываем противоположную  |
//|     позицию своим магиком, замораживая убыток. При откате на     |
//|     N% от пика DD хедж снимается первым (расколачивание).        |
//|   * Частичное закрытие: на «первом откате» от пика просадки      |
//|     закрываем самую тяжёлую позицию (по выбору: max-лот /        |
//|     max-убыток / первая / последняя), снижая нагрузку на счёт.   |
//|   * Импорт сигналов EvasiveST_FBG: первый вход по ST-флипу,      |
//|     по стрелке Герчика или по любому из них (через iCustom).     |
//+------------------------------------------------------------------+
#property copyright "Devin"
#property version   "1.20"
#property description "Универсальный советник вытаскивания счёта из просадки (ATR-сетка, корзина TP, хедж-лок с парным расколачиванием)"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/AccountInfo.mqh>

//================== Перечисления ===================================
enum ENUM_RESCUE_DIR
  {
   RDIR_TREND      = 0, // По тренду (EMA fast/slow)
   RDIR_COUNTER    = 1, // Против тренда
   RDIR_BUY_ONLY   = 2, // Только Buy
   RDIR_SELL_ONLY  = 3, // Только Sell
   RDIR_BOTH       = 4  // Обе стороны (хедж-режим, требуется netting=off)
  };

enum ENUM_LOT_PROGRESS
  {
   LOT_FIXED      = 0, // Фиксированный лот на каждый ордер
   LOT_LINEAR     = 1, // База * (1 + k*(n-1))
   LOT_GEOMETRIC  = 2, // База * k^(n-1)
   LOT_FIBONACCI  = 3  // База * Fib(n)
  };

enum ENUM_TP_MODE
  {
   TP_PERCENT_EQUITY = 0, // % от баланса
   TP_PIPS           = 1, // Пункты от средней цены корзины
   TP_MONEY          = 2  // Сумма в валюте депозита
  };

enum ENUM_INITIAL_LOT_MODE
  {
   ILM_FIXED         = 0, // Фиксированный лот
   ILM_RISK_PCT      = 1  // % риска от баланса (по InpRiskStopPips)
  };

//--- Источник сигнала первого входа (v1.10)
enum ENUM_ENTRY_TRIGGER
  {
   TRG_EMA          = 0, // EMA fast/slow тренд (как в v1.00)
   TRG_FBG_ST_FLIP  = 1, // EvasiveST_FBG: только флип СуперТренда
   TRG_FBG_ARROW    = 2, // EvasiveST_FBG: только стрелка Герчика
   TRG_FBG_ANY      = 3  // EvasiveST_FBG: ST-флип ИЛИ стрелка Герчика
  };

//--- Что закрывать при частичном восстановлении (v1.10)
enum ENUM_PARTIAL_TARGET
  {
   PCT_LARGEST_LOT     = 0, // Самая крупная по объёму
   PCT_BIGGEST_LOSS    = 1, // С самым большим убытком (только если разрешено закрывать в минус)
   PCT_FIRST_OPENED    = 2, // Самая старая
   PCT_LAST_OPENED     = 3, // Самая новая (последнее усреднение)
   PCT_BIGGEST_PROFIT  = 4  // С самой большой прибылью (по умолчанию — фиксация плюсов)
  };

//================== Входные параметры ==============================
input group "=== Общие ==="
input long             InpMagic              = 20260518;     // Magic Number
input string           InpTradeComment       = "DDRescue";   // Комментарий ордеров
input bool             InpManageManualTrades = true;         // Управлять ручными сделками по символу

input group "=== Защита счёта (предохранители) ==="
input bool             InpUseEquityStop      = true;         // Включить Equity-Stop
input double           InpEquityStopPct      = 25.0;         // Экстренный стоп: просадка от баланса, %
input bool             InpUseDailyLossLimit  = true;         // Включить дневной лимит потерь
input double           InpDailyLossPct       = 8.0;          // Дневной лимит потерь, % от баланса дня
input bool             InpDisableAfterLimit  = true;         // Запретить новые сделки после срабатывания
input bool             InpCloseOnFriday      = true;         // Закрывать всё в пятницу
input int              InpFridayCloseHour    = 22;           // Час пятничного закрытия (терминальное время)
input int              InpMaxSpreadPts       = 50;           // Макс. спред (пункты трейдера, 0=выкл.)

input group "=== Триггер режима спасения ==="
input double           InpDrawdownStartPct   = 1.0;          // % просадки депозита для активации усреднения
input bool             InpAutoTradeFirst     = true;         // Открывать первую сделку самостоятельно
input ENUM_RESCUE_DIR  InpDirection          = RDIR_TREND;   // Направление торговли

input group "=== Размер первой сделки ==="
input ENUM_INITIAL_LOT_MODE InpInitialLotMode = ILM_FIXED;   // Способ расчёта первого лота
input double           InpInitialLot         = 0.01;         // Фиксированный лот
input double           InpRiskPct            = 0.5;          // Риск, % от баланса (для режима риска)
input double           InpRiskStopPips       = 200;          // Условный стоп для расчёта риска (пункты)

input group "=== Сетка усреднения ==="
input ENUM_LOT_PROGRESS InpLotProgress       = LOT_LINEAR;   // Прогрессия лотов
input double           InpLotMultiplier      = 1.5;          // Множитель прогрессии (для лин/гео)
input int              InpATRPeriod          = 14;           // Период ATR
input ENUM_TIMEFRAMES  InpATRTimeframe       = PERIOD_H1;    // Таймфрейм ATR
input double           InpStepATRMult        = 1.0;          // Шаг сетки = N * ATR
input double           InpStepMinPips        = 50;           // Мин. шаг (пункты, 0=выкл.)
input double           InpStepMaxPips        = 5000;         // Макс. шаг (пункты, 0=выкл.)
input int              InpMaxAverages        = 10;           // Макс. число усреднений на сторону
input double           InpMaxTotalLot        = 5.0;          // Макс. совокупный лот (0=выкл.)

input group "=== Профит корзины ==="
input ENUM_TP_MODE     InpTPMode             = TP_PERCENT_EQUITY; // Режим тейк-профита
input double           InpBasketTPPct        = 0.5;          // % от баланса
input double           InpBasketTPPips       = 100;          // Пункты от средней цены
input double           InpBasketTPMoney      = 50;           // Сумма в валюте депозита
input bool             InpBreakevenAfterN    = true;         // Брэйк-ивен после N усреднений
input int              InpAveragesForBE      = 3;            // N усреднений до брэйк-ивена

input group "=== Трендовый фильтр (для авто-входа) ==="
input ENUM_ENTRY_TRIGGER InpEntryTrigger     = TRG_EMA;      // Источник сигнала первого входа
input int              InpFastEMA            = 50;           // Быстрая EMA (для TRG_EMA)
input int              InpSlowEMA            = 200;          // Медленная EMA (для TRG_EMA)
input ENUM_TIMEFRAMES  InpTrendTF            = PERIOD_H1;    // ТФ для EMA-фильтра

input group "=== Импорт сигналов EvasiveST_FBG (v1.10) ==="
input string           InpFBGIndicator       = "EvasiveST_FBG"; // Имя файла индикатора (без .ex5)
input int              InpFBGSignalShift     = 1;            // Бар сигнала: 1=последний закрытый, 0=текущий
input bool             InpFBGRespectIndicatorTrend = true;   // Сверять направление с InpDirection (например, TREND ⊕ FBG)

input group "=== Хедж-лок (v1.10) ==="
input bool             InpUseHedgeLock       = false;        // Включить хедж-лок (требуется хедж-счёт)
input double           InpHedgeLockDDPct     = 5.0;          // % просадки для открытия хеджа
input int              InpHedgeLockMinAvg    = 3;            // Мин. число усреднений на стороне до хеджа
input double           InpHedgeLockRatio     = 1.0;          // Доля совокупного лота под хедж (1.0 = полный)
input long             InpHedgeMagicOffset   = 1;            // Смещение магика для хеджа (Magic+offset)
input double           InpHedgeUnlockDDPct   = 50.0;         // % восстановления от пика DD для расколачивания
input bool             InpHedgeBlockAveraging = true;        // Запретить усреднение пока хедж активен

input group "=== Парное расколачивание лока (v1.20) ==="
input bool             InpUseUnlockPairs     = true;         // Закрывать пары (хедж + корзина) парами без убытка
input double           InpUnlockPairMinProfitMoney = 0.0;    // Мин. прибыль пары после закрытия (валюта депо)
input double           InpUnlockSafetyMoney  = 1.0;          // Резерв на проскальзывание (валюта депо)
input bool             InpHedgeCloseOnlyInProfit = true;     // Закрывать хедж полностью ТОЛЬКО если он в плюсе
input double           InpHedgeMinProfitToClose = 0.0;       // Мин. прибыль хеджа для его закрытия (валюта депо)

input group "=== Частичное закрытие на откате (v1.10) ==="
input bool             InpUsePartialClose    = false;        // Включить частичное закрытие
input bool             InpPartialOnlyProfitable = true;      // Закрывать ТОЛЬКО прибыльные позиции (никаких убытков)
input int              InpPartialMinAverages = 3;            // Мин. число усреднений на стороне
input double           InpPartialMinDDPct    = 3.0;          // Мин. достигнутая просадка для активации
input double           InpPartialRecoveryPct = 30.0;         // % восстановления от пика DD
input ENUM_PARTIAL_TARGET InpPartialTarget   = PCT_BIGGEST_PROFIT; // Какую позицию закрывать
input int              InpPartialCooldownSec = 600;          // Кулдаун между частичными закрытиями, сек

input group "=== Информация / лог ==="
input bool             InpShowDashboard      = true;         // Панель состояния на графике
input bool             InpVerboseLog         = false;        // Подробный лог в журнал

//================== Глобальное состояние ===========================
CTrade           Trade;
CSymbolInfo      Sym;
CPositionInfo    Pos;
CAccountInfo     Acc;

int              g_atrHandle = INVALID_HANDLE;
int              g_emaFastHandle = INVALID_HANDLE;
int              g_emaSlowHandle = INVALID_HANDLE;
int              g_fbgHandle = INVALID_HANDLE;     // (v1.10) iCustom EvasiveST_FBG

datetime         g_dayStart = 0;
double           g_dayStartBalance = 0.0;
bool             g_dailyLimitHit = false;
bool             g_equityStopHit = false;

double           g_pip = 0.0;     // размер «пункта трейдера» (с учётом 3/5-знаков)
int              g_pipDigits = 0; // 1 если 3/5-знаков, иначе 0

//--- (v1.10) Хедж-лок
bool             g_hedgeActive = false;
int              g_hedgeSide   = 0;     // +1 хедж BUY (защищает Sell-корзину), -1 хедж SELL
double           g_hedgeLot    = 0.0;
double           g_hedgePeakDD = 0.0;   // пиковая просадка с момента активации хеджа

//--- (v1.10) Трек пика DD для частичного закрытия
double           g_basketPeakDD = 0.0;
datetime         g_lastPartialCloseTime = 0;

const string     DASH_NAME = "DDRescue_Dashboard";
const string     HEDGE_TAG = "HDG"; // маркер в комментарии хедж-позиции

//================== Утилиты ========================================

//--- Размер «пункта трейдера»: для 3 и 5 знаков _Point*10
double PipSize()
  {
   int d = (int)_Digits;
   if(d == 3 || d == 5) return _Point * 10.0;
   return _Point;
  }

//--- Перевод пунктов трейдера в цену
double PipsToPrice(const double pips)
  {
   return pips * g_pip;
  }

//--- Нормализация лота под спецификацию символа
double NormalizeLot(double lot)
  {
   double minLot = Sym.LotsMin();
   double maxLot = Sym.LotsMax();
   double step   = Sym.LotsStep();
   if(step <= 0.0) step = 0.01;
   lot = MathRound(lot / step) * step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return NormalizeDouble(lot, 2);
  }

//--- Получить ATR (последняя сформированная свеча)
double GetATR()
  {
   if(g_atrHandle == INVALID_HANDLE) return 0.0;
   double buf[];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) != 1) return 0.0;
   return buf[0];
  }

//--- Тренд: +1 / -1 / 0
int GetTrendSide()
  {
   if(g_emaFastHandle == INVALID_HANDLE || g_emaSlowHandle == INVALID_HANDLE) return 0;
   double fast[], slow[];
   if(CopyBuffer(g_emaFastHandle, 0, 1, 1, fast) != 1) return 0;
   if(CopyBuffer(g_emaSlowHandle, 0, 1, 1, slow) != 1) return 0;
   if(fast[0] > slow[0]) return +1;
   if(fast[0] < slow[0]) return -1;
   return 0;
  }

//--- Спред в пунктах трейдера
double SpreadPips()
  {
   long spreadPts = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double rawPts = (double)spreadPts;
   // SYMBOL_SPREAD — в _Point. Переведём в пункты трейдера:
   if(g_pip > _Point + 1e-12) return rawPts / 10.0;
   return rawPts;
  }

//--- Ограничения брокера: минимальное расстояние от текущей цены до стопов
double StopsLevelPrice()
  {
   long stops = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   return ((double)stops) * _Point;
  }

//--- День начался — сбрасываем дневные счётчики
void RolloverDailyState()
  {
   datetime now = TimeCurrent();
   MqlDateTime st;
   TimeToStruct(now, st);
   st.hour = 0; st.min = 0; st.sec = 0;
   datetime today = StructToTime(st);
   if(today != g_dayStart)
     {
      g_dayStart = today;
      g_dayStartBalance = Acc.Balance();
      g_dailyLimitHit = false;
      if(InpVerboseLog)
         PrintFormat("[DDRescue] New day. StartBalance=%.2f", g_dayStartBalance);
     }
  }

//================== Информация о корзине =========================
struct BasketInfo
  {
   int      buyCount;
   int      sellCount;
   double   buyLots;
   double   sellLots;
   double   buyVwap;       // средневзвешенная цена Buy
   double   sellVwap;      // средневзвешенная цена Sell
   double   floatingPL;    // плавающий результат корзины советника
   double   floatingAll;   // плавающий результат всех позиций по символу
   datetime lastBuyTime;
   datetime lastSellTime;
   double   lastBuyPrice;
   double   lastSellPrice;
   double   minBuyPrice;   // самая «нижняя» цена входа Buy (где нам больнее всего)
   double   maxSellPrice;  // самая «верхняя» цена входа Sell
  };

void GetBasket(BasketInfo &b)
  {
   ZeroMemory(b);
   b.minBuyPrice  = DBL_MAX;
   b.maxSellPrice = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      if(!Pos.SelectByIndex(i)) continue;
      if(Pos.Symbol() != _Symbol) continue;

      bool ours = (Pos.Magic() == InpMagic);
      bool isHedge = (Pos.Magic() == HedgeMagic());
      bool manual = (Pos.Magic() != InpMagic && !isHedge);
      if(isHedge) continue; // (v1.10) хедж учитывается отдельно
      if(!ours && !(InpManageManualTrades && manual)) continue;

      double vol  = Pos.Volume();
      double pop  = Pos.PriceOpen();
      double pcur = Pos.PriceCurrent();
      datetime t  = (datetime)Pos.Time();
      double pl   = Pos.Profit() + Pos.Swap() + Pos.Commission();
      b.floatingAll += pl;

      if(Pos.PositionType() == POSITION_TYPE_BUY)
        {
         b.buyCount++;
         b.buyVwap = (b.buyVwap * b.buyLots + pop * vol);
         b.buyLots += vol;
         if(b.buyLots > 0.0) b.buyVwap /= b.buyLots;
         if(t > b.lastBuyTime) { b.lastBuyTime = t; b.lastBuyPrice = pop; }
         if(pop < b.minBuyPrice) b.minBuyPrice = pop;
         b.floatingPL += pl;
        }
      else if(Pos.PositionType() == POSITION_TYPE_SELL)
        {
         b.sellCount++;
         b.sellVwap = (b.sellVwap * b.sellLots + pop * vol);
         b.sellLots += vol;
         if(b.sellLots > 0.0) b.sellVwap /= b.sellLots;
         if(t > b.lastSellTime) { b.lastSellTime = t; b.lastSellPrice = pop; }
         if(pop > b.maxSellPrice) b.maxSellPrice = pop;
         b.floatingPL += pl;
        }
     }
   if(b.minBuyPrice == DBL_MAX) b.minBuyPrice = 0.0;
  }

//--- Закрыть все позиции советника по символу
bool CloseAllOurs(const string reason)
  {
   bool ok = true;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      if(!Pos.SelectByIndex(i)) continue;
      if(Pos.Symbol() != _Symbol) continue;
      bool ours = (Pos.Magic() == InpMagic);
      bool isHedge = (Pos.Magic() == HedgeMagic());
      bool manual = (Pos.Magic() != InpMagic && !isHedge);
      if(isHedge) continue; // (v1.10) хедж закрывается отдельно через CloseAllHedges
      if(!ours && !(InpManageManualTrades && manual)) continue;
      ulong ticket = Pos.Ticket();
      if(!Trade.PositionClose(ticket))
        {
         PrintFormat("[DDRescue] Закрытие #%I64u не удалось: %s", ticket, Trade.ResultRetcodeDescription());
         ok = false;
        }
     }
   if(ok && InpVerboseLog) PrintFormat("[DDRescue] Корзина закрыта: %s", reason);
   return ok;
  }

//================== Расчёт лота ===================================

//--- Лот первой сделки
double FirstLot()
  {
   if(InpInitialLotMode == ILM_FIXED) return NormalizeLot(InpInitialLot);
   // Режим риска: лот так, чтобы потеря на InpRiskStopPips составила InpRiskPct % баланса
   double balance = Acc.Balance();
   double riskMoney = balance * InpRiskPct / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0) return NormalizeLot(InpInitialLot);
   double pricePerLot = (PipsToPrice(InpRiskStopPips) / tickSize) * tickValue;
   if(pricePerLot <= 0.0) return NormalizeLot(InpInitialLot);
   double lot = riskMoney / pricePerLot;
   return NormalizeLot(lot);
  }

//--- Число Фибоначчи (1,1,2,3,5,8,13,...)
int Fib(int n)
  {
   if(n <= 1) return 1;
   int a = 1, b = 1;
   for(int i = 2; i <= n; ++i) { int c = a + b; a = b; b = c; }
   return b;
  }

//--- Лот N-го усреднения (n=1 — первая сделка)
double LotForOrder(const int n)
  {
   double base = FirstLot();
   double k = MathMax(1.0, InpLotMultiplier);
   double lot = base;
   switch(InpLotProgress)
     {
      case LOT_FIXED:     lot = base; break;
      case LOT_LINEAR:    lot = base * (1.0 + k * (n - 1)); break;
      case LOT_GEOMETRIC: lot = base * MathPow(k, n - 1); break;
      case LOT_FIBONACCI: lot = base * (double)Fib(n); break;
     }
   return NormalizeLot(lot);
  }

//--- Шаг сетки в ценовых единицах
double GridStepPrice()
  {
   double atr = GetATR();
   double step = atr * InpStepATRMult;
   double minS = (InpStepMinPips > 0.0) ? PipsToPrice(InpStepMinPips) : 0.0;
   double maxS = (InpStepMaxPips > 0.0) ? PipsToPrice(InpStepMaxPips) : DBL_MAX;
   if(step < minS) step = minS;
   if(step > maxS) step = maxS;
   double stops = StopsLevelPrice();
   if(step < stops * 1.5) step = stops * 1.5; // запас от уровня брокера
   return step;
  }

//================== Тейк-профит корзины ===========================

//--- Расчёт целевого PnL корзины в валюте депозита
double TargetMoney(const BasketInfo &b)
  {
   switch(InpTPMode)
     {
      case TP_PERCENT_EQUITY: return Acc.Balance() * InpBasketTPPct / 100.0;
      case TP_MONEY:          return InpBasketTPMoney;
      case TP_PIPS:
        {
         // Перевод пунктов в деньги через средний лот: считаем по совокупному лоту наибольшей стороны
         double lots = MathMax(b.buyLots, b.sellLots);
         if(lots <= 0.0) return 0.0;
         double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
         double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
         if(tickValue <= 0.0 || tickSize <= 0.0) return 0.0;
         return (PipsToPrice(InpBasketTPPips) / tickSize) * tickValue * lots;
        }
     }
   return 0.0;
  }

//--- Брэйк-ивен порог (около нуля + комиссии/свопы)
bool BasketHitBreakeven(const BasketInfo &b)
  {
   if(!InpBreakevenAfterN) return false;
   int total = b.buyCount + b.sellCount;
   if(total < InpAveragesForBE + 1) return false; // первый ордер + N усреднений
   // Берём около нуля; +0.1% от баланса как «небольшой плюс»
   double eps = Acc.Balance() * 0.001;
   return (b.floatingPL >= eps);
  }

bool BasketHitTarget(const BasketInfo &b)
  {
   if(b.buyCount + b.sellCount == 0) return false;
   double target = TargetMoney(b);
   if(target <= 0.0) return false;
   return (b.floatingPL >= target);
  }

//================== Открытие сделок ===============================

//--- Открыть рыночную позицию
bool OpenMarket(const int side, const double lot, const string why)
  {
   if(lot <= 0.0) return false;
   Sym.RefreshRates();
   double price = (side > 0) ? Sym.Ask() : Sym.Bid();
   string cmt = StringFormat("%s|%s", InpTradeComment, why);
   bool ok = (side > 0) ? Trade.Buy(lot, _Symbol, price, 0.0, 0.0, cmt)
                        : Trade.Sell(lot, _Symbol, price, 0.0, 0.0, cmt);
   if(!ok)
      PrintFormat("[DDRescue] Открытие %s lot=%.2f не удалось: %s",
                  (side > 0) ? "BUY" : "SELL", lot, Trade.ResultRetcodeDescription());
   else if(InpVerboseLog)
      PrintFormat("[DDRescue] OPEN %s lot=%.2f price=%.5f reason=%s",
                  (side > 0) ? "BUY" : "SELL", lot, price, why);
   return ok;
  }

//================== Решение о входе ===============================

//--- Сигнальная сторона по выбранному источнику (EMA или FBG-индикатор)
//    Возвращает +1 / -1 / 0
int SignalSide()
  {
   if(InpEntryTrigger == TRG_EMA) return GetTrendSide();
   return FBGSignalSide(); // FBG_ST_FLIP / FBG_ARROW / FBG_ANY
  }

//--- Разрешённое направление по настройкам и сигналу источника
//    Возвращает +1, -1 или 0 (запрещено / нейтрально)
int AllowedSide()
  {
   int sig = SignalSide();
   //--- Если выбран FBG и пользователь не хочет «дополнительной» фильтрации —
   //    возвращаем сторону прямо из индикатора без модификации (BUY_ONLY/SELL_ONLY всё равно держим).
   if(InpEntryTrigger != TRG_EMA && !InpFBGRespectIndicatorTrend)
     {
      if(InpDirection == RDIR_BUY_ONLY)  return (sig > 0) ? +1 : 0;
      if(InpDirection == RDIR_SELL_ONLY) return (sig < 0) ? -1 : 0;
      return sig;
     }
   switch(InpDirection)
     {
      case RDIR_BUY_ONLY:  return (sig >= 0) ? +1 : 0;
      case RDIR_SELL_ONLY: return (sig <= 0) ? -1 : 0;
      case RDIR_TREND:     return sig;
      case RDIR_COUNTER:   return -sig;
      case RDIR_BOTH:      return (sig == 0) ? +1 : sig;
     }
   return 0;
  }

//--- Условие открытия N-го усреднения для стороны
bool ShouldAverage(const int side, const BasketInfo &b)
  {
   //--- (v1.10) При активном хедж-локе усреднение запрещено,
   //    пока не сработал расколачивающий триггер.
   if(g_hedgeActive && InpHedgeBlockAveraging) return false;

   // Требуем активацию режима спасения по просадке
   double balance = Acc.Balance();
   double equity  = Acc.Equity();
   double ddPct = (balance > 0.0) ? (balance - equity) * 100.0 / balance : 0.0;
   if(ddPct < InpDrawdownStartPct) return false;

   int count = (side > 0) ? b.buyCount : b.sellCount;
   if(count == 0) return false; // первая сделка открывается отдельно
   if(count >= InpMaxAverages) return false;

   double lastPrice = (side > 0) ? b.lastBuyPrice : b.lastSellPrice;
   if(lastPrice <= 0.0) return false;
   double step = GridStepPrice();
   if(step <= 0.0) return false;

   Sym.RefreshRates();
   double cur = (side > 0) ? Sym.Ask() : Sym.Bid();
   // Усредняемся ТОЛЬКО при движении ПРОТИВ позиции на >=step
   if(side > 0 && (lastPrice - cur) < step) return false;
   if(side < 0 && (cur - lastPrice) < step) return false;

   // Лимит совокупного лота
   double newLot = LotForOrder(count + 1);
   double totalLot = b.buyLots + b.sellLots + newLot;
   if(InpMaxTotalLot > 0.0 && totalLot > InpMaxTotalLot) return false;
   return true;
  }

//================== Предохранители =================================

//--- Equity-Stop: если просадка от баланса больше порога — закрыть всё
bool CheckEquityStop()
  {
   if(!InpUseEquityStop) return false;
   double balance = Acc.Balance();
   double equity  = Acc.Equity();
   if(balance <= 0.0) return false;
   double ddPct = (balance - equity) * 100.0 / balance;
   if(ddPct >= InpEquityStopPct)
     {
      g_equityStopHit = true;
      PrintFormat("[DDRescue] EQUITY-STOP сработал: dd=%.2f%% >= %.2f%%. Закрываю всё.",
                  ddPct, InpEquityStopPct);
      CloseAllOurs("equity-stop");
      return true;
     }
   return false;
  }

//--- Дневной лимит потерь
bool CheckDailyLoss()
  {
   if(!InpUseDailyLossLimit) return false;
   if(g_dayStartBalance <= 0.0) return false;
   double equity = Acc.Equity();
   double loss = g_dayStartBalance - equity;
   double pct = loss * 100.0 / g_dayStartBalance;
   if(pct >= InpDailyLossPct)
     {
      if(!g_dailyLimitHit)
        {
         g_dailyLimitHit = true;
         PrintFormat("[DDRescue] Дневной лимит достигнут: -%.2f%% от %.2f. Закрываю корзину.",
                     pct, g_dayStartBalance);
         CloseAllOurs("daily-loss");
        }
      return true;
     }
   return false;
  }

//--- Пятничное закрытие
bool CheckFridayClose()
  {
   if(!InpCloseOnFriday) return false;
   MqlDateTime st;
   TimeToStruct(TimeCurrent(), st);
   if(st.day_of_week == 5 && st.hour >= InpFridayCloseHour)
     {
      CloseAllOurs("friday");
      return true;
     }
   return false;
  }

//--- Спред в пределах лимита
bool SpreadOk()
  {
   if(InpMaxSpreadPts <= 0) return true;
   double s = SpreadPips();
   return (s <= (double)InpMaxSpreadPts);
  }

//================== EvasiveST_FBG: импорт сигналов (v1.10) =========

//--- Прочитать значение указанного буфера индикатора на заданном баре.
//    Возвращает EMPTY_VALUE при ошибке.
double FBGBuffer(const int bufferIndex, const int shift)
  {
   if(g_fbgHandle == INVALID_HANDLE) return EMPTY_VALUE;
   double v[];
   if(CopyBuffer(g_fbgHandle, bufferIndex, shift, 1, v) != 1) return EMPTY_VALUE;
   return v[0];
  }

//--- Сторона сигнала индикатора по выбранному источнику.
//    +1 / -1 / 0 (нет сигнала)
int FBGSignalSide()
  {
   if(g_fbgHandle == INVALID_HANDLE) return 0;
   int s = MathMax(0, InpFBGSignalShift);

   //--- индексы буферов EvasiveST_FBG (см. описание индикатора):
   //    4=ST Bull, 5=ST Bear, 11=FBG Buy, 12=FBG Sell
   double stBull = FBGBuffer(4,  s);
   double stBear = FBGBuffer(5,  s);
   double fbgBuy = FBGBuffer(11, s);
   double fbgSel = FBGBuffer(12, s);

   bool bullST  = (stBull  != EMPTY_VALUE && stBull  != 0.0);
   bool bearST  = (stBear  != EMPTY_VALUE && stBear  != 0.0);
   bool bullFBG = (fbgBuy  != EMPTY_VALUE && fbgBuy  != 0.0);
   bool bearFBG = (fbgSel  != EMPTY_VALUE && fbgSel  != 0.0);

   bool bull=false, bear=false;
   switch(InpEntryTrigger)
     {
      case TRG_FBG_ST_FLIP: bull = bullST;            bear = bearST;            break;
      case TRG_FBG_ARROW:   bull = bullFBG;           bear = bearFBG;           break;
      case TRG_FBG_ANY:     bull = bullST || bullFBG; bear = bearST || bearFBG; break;
      default:              return 0; // TRG_EMA — не наш режим
     }
   if(bull && !bear) return +1;
   if(bear && !bull) return -1;
   return 0;
  }

//================== Хедж-лок (v1.10) ===============================

long HedgeMagic() { return InpMagic + InpHedgeMagicOffset; }

//--- Сканирование позиций по хедж-магику
void GetHedgeBasket(int &count, double &lot, int &side, double &pl)
  {
   count = 0; lot = 0.0; side = 0; pl = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      if(!Pos.SelectByIndex(i)) continue;
      if(Pos.Symbol() != _Symbol) continue;
      if(Pos.Magic()  != HedgeMagic()) continue;
      count++;
      lot += Pos.Volume();
      side = (Pos.PositionType() == POSITION_TYPE_BUY) ? +1 : -1;
      pl  += Pos.Profit() + Pos.Swap() + Pos.Commission();
     }
  }

bool IsHedgingAccount()
  {
   long mode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   return (mode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
  }

//--- Открыть хедж-позицию своим магиком
bool OpenHedge(const int side, const double lot)
  {
   if(lot <= 0.0) return false;
   if(!IsHedgingAccount())
     {
      Print("[DDRescue] Хедж-лок невозможен: счёт в режиме неттинга");
      return false;
     }
   Trade.SetExpertMagicNumber(HedgeMagic());
   Sym.RefreshRates();
   double price = (side > 0) ? Sym.Ask() : Sym.Bid();
   string cmt = StringFormat("%s|%s", InpTradeComment, HEDGE_TAG);
   bool ok = (side > 0) ? Trade.Buy(lot, _Symbol, price, 0.0, 0.0, cmt)
                        : Trade.Sell(lot, _Symbol, price, 0.0, 0.0, cmt);
   Trade.SetExpertMagicNumber(InpMagic); // вернули обычный магик
   if(!ok)
      PrintFormat("[DDRescue] Открытие хеджа %s lot=%.2f не удалось: %s",
                  (side > 0) ? "BUY" : "SELL", lot, Trade.ResultRetcodeDescription());
   else
      PrintFormat("[DDRescue] HEDGE OPEN %s lot=%.2f price=%.5f",
                  (side > 0) ? "BUY" : "SELL", lot, price);
   return ok;
  }

//--- Закрыть все хедж-позиции
bool CloseAllHedges(const string reason)
  {
   bool ok = true;
   bool anyClosed = false;
   Trade.SetExpertMagicNumber(HedgeMagic());
   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      if(!Pos.SelectByIndex(i)) continue;
      if(Pos.Symbol() != _Symbol) continue;
      if(Pos.Magic()  != HedgeMagic()) continue;
      anyClosed = true;
      if(!Trade.PositionClose(Pos.Ticket()))
        {
         PrintFormat("[DDRescue] Закрытие хеджа #%I64u не удалось: %s",
                     Pos.Ticket(), Trade.ResultRetcodeDescription());
         ok = false;
        }
     }
   Trade.SetExpertMagicNumber(InpMagic);
   if(ok && anyClosed) PrintFormat("[DDRescue] HEDGES CLOSED: %s", reason);
   return ok;
  }

//--- Обновление состояния хеджа: фиксируем активность по факту наличия позиций
void RefreshHedgeState()
  {
   int hcount; double hlot; int hside; double hpl;
   GetHedgeBasket(hcount, hlot, hside, hpl);
   bool wasActive = g_hedgeActive;
   g_hedgeActive = (hcount > 0);
   g_hedgeLot    = hlot;
   g_hedgeSide   = hside;
   if(g_hedgeActive && !wasActive)
     {
      // Хедж только что появился (или восстановлен после рестарта) — сбросим пик
      double balance = Acc.Balance();
      double equity  = Acc.Equity();
      g_hedgePeakDD = (balance > 0.0) ? (balance - equity) * 100.0 / balance : 0.0;
     }
   if(!g_hedgeActive)
     {
      g_hedgeLot = 0.0;
      g_hedgeSide = 0;
     }
  }

//--- Решение об открытии хеджа
//    side — сторона КОРЗИНЫ, которую нужно защитить (та, где сейчас убыток).
//    Хедж открывается в противоположную сторону.
bool ShouldOpenHedge(const BasketInfo &b, int &trappedSide)
  {
   trappedSide = 0;
   if(!InpUseHedgeLock) return false;
   if(g_hedgeActive)    return false;
   if(!IsHedgingAccount()) return false;

   double balance = Acc.Balance();
   double equity  = Acc.Equity();
   if(balance <= 0.0) return false;
   double ddPct = (balance - equity) * 100.0 / balance;
   if(ddPct < InpHedgeLockDDPct) return false;

   // Какая сторона убыточна? Та, где плавающий PnL по своей стороне самый отрицательный
   // и где есть достаточно усреднений.
   double buyPL = 0.0, sellPL = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      if(!Pos.SelectByIndex(i)) continue;
      if(Pos.Symbol() != _Symbol) continue;
      if(Pos.Magic() != InpMagic && !(InpManageManualTrades && Pos.Magic() != HedgeMagic())) continue;
      if(Pos.Magic() == HedgeMagic()) continue;
      double pl = Pos.Profit() + Pos.Swap() + Pos.Commission();
      if(Pos.PositionType() == POSITION_TYPE_BUY)  buyPL  += pl;
      else                                          sellPL += pl;
     }
   if(buyPL >= 0.0 && sellPL >= 0.0) return false;

   if(buyPL <= sellPL && b.buyCount  >= InpHedgeLockMinAvg) trappedSide = +1;
   else if(b.sellCount >= InpHedgeLockMinAvg)               trappedSide = -1;
   else return false;
   return true;
  }

//--- Размер хеджа: ratio * (совокупный лот защищаемой стороны)
double HedgeLotFor(const int trappedSide, const BasketInfo &b)
  {
   double base = (trappedSide > 0) ? b.buyLots : b.sellLots;
   double lot = base * MathMax(0.1, InpHedgeLockRatio);
   return NormalizeLot(lot);
  }

//--- Условия снятия хеджа полностью.
//    (v1.20) По умолчанию хедж закрывается только если ОН САМ в плюсе на
//    InpHedgeMinProfitToClose. Закрытие хеджа в минус считается реализацией
//    убытка и запрещено пользовательской политикой. Старая логика
//    «восстановление от пика DD» осталась как дополнительное условие.
bool ShouldUnlockHedge()
  {
   if(!g_hedgeActive) return false;

   //--- (v1.20) текущий PnL хеджа
   int hcount; double hlot; int hside; double hpl;
   GetHedgeBasket(hcount, hlot, hside, hpl);
   if(hcount == 0) return false;

   //--- (v1.20) основное условие: хедж сам в плюсе
   if(InpHedgeCloseOnlyInProfit && hpl < InpHedgeMinProfitToClose) return false;

   //--- (v1.10) дополнительное условие "восстановление от пика DD" — оставлено
   //    для совместимости. Если хедж уже в плюсе (или фильтр выключен) и DD
   //    ещё не восстановилась — всё равно можно закрыть, потому что это плюс.
   double balance = Acc.Balance();
   double equity  = Acc.Equity();
   if(balance <= 0.0) return true;
   double ddPct = (balance - equity) * 100.0 / balance;
   if(ddPct > g_hedgePeakDD) g_hedgePeakDD = ddPct;
   return true;
  }

//--- (v1.20) Получить тикет хедж-позиции (она у нас одна) и её данные
ulong GetHedgeTicket(double &hpl, double &hvol, int &hside)
  {
   hpl = 0.0; hvol = 0.0; hside = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      if(!Pos.SelectByIndex(i)) continue;
      if(Pos.Symbol() != _Symbol) continue;
      if(Pos.Magic()  != HedgeMagic()) continue;
      hpl  = Pos.Profit() + Pos.Swap() + Pos.Commission();
      hvol = Pos.Volume();
      hside = (Pos.PositionType() == POSITION_TYPE_BUY) ? +1 : -1;
      return Pos.Ticket();
     }
   return 0;
  }

//--- (v1.20) ПАРНОЕ РАСКОЛАЧИВАНИЕ ЛОКА.
//    Когда хедж в плюсе, ищем корзинную позицию (любой стороны кроме хедж-стороны),
//    у которой убыток ≤ (прибыль хеджа − резерв − мин. прибыль пары). Закрываем
//    обе одновременно: хедж частично на объём корзинной, корзинную — полностью.
//    Сумма пары после закрытия гарантированно >= 0 (минимум — InpUnlockPairMinProfitMoney).
//    Если в корзине нашлась плюсовая позиция, выбираем её (закрываем без условия
//    на резерв — двойной плюс ещё лучше).
//    Возвращает true, если выполнили закрытие пары на этом тике.
bool TryUnlockPair()
  {
   if(!InpUseUnlockPairs) return false;
   if(!g_hedgeActive)     return false;

   double hpl, hvol; int hside;
   ulong hticket = GetHedgeTicket(hpl, hvol, hside);
   if(hticket == 0) return false;

   //--- (v1.20) Хедж должен быть в плюсе с запасом
   double available = hpl - InpUnlockSafetyMoney - InpUnlockPairMinProfitMoney;
   if(available <= 0.0) return false; // на покрытие убытка корзинной позиции не хватает

   //--- Ищем корзинную позицию противоположной хеджу стороны (= трапнутая сторона)
   //    с такими свойствами:
   //    - объём ≤ объёма хеджа (иначе не сможем закрыть хедж парным объёмом),
   //    - PnL >= -available (убыток помещается в плюс хеджа),
   //    - предпочитаем плюсовые, потом — самые "дешёвые" (минимальный убыток).
   ulong bestTk = 0;
   double bestVol = 0.0;
   double bestPL  = -DBL_MAX;
   int trappedSide = -hside;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      if(!Pos.SelectByIndex(i)) continue;
      if(Pos.Symbol() != _Symbol) continue;
      bool ours   = (Pos.Magic() == InpMagic);
      bool manual = (Pos.Magic() != InpMagic && Pos.Magic() != HedgeMagic());
      if(!ours && !(InpManageManualTrades && manual)) continue;

      int psd = (Pos.PositionType() == POSITION_TYPE_BUY) ? +1 : -1;
      if(psd != trappedSide) continue; // только трапнутую сторону

      double vol = Pos.Volume();
      if(vol > hvol + 1e-9) continue; // не закроем хедж парным объёмом

      double pl  = Pos.Profit() + Pos.Swap() + Pos.Commission();
      if(pl < -available) continue;   // убыток не покрывается прибылью хеджа

      //--- Лучший = с максимальным PnL (предпочтение плюсовым)
      if(pl > bestPL)
        {
         bestPL  = pl;
         bestVol = vol;
         bestTk  = Pos.Ticket();
        }
     }

   if(bestTk == 0) return false;

   //--- Закрываем пару: сначала корзинную целиком, потом хедж частично на объём корзинной
   if(!Trade.PositionClose(bestTk))
     {
      PrintFormat("[DDRescue] UNLOCK pair: close basket #%I64u failed: %s",
                  bestTk, Trade.ResultRetcodeDescription());
      return false;
     }

   //--- Закрытие части хеджа объёмом bestVol
   bool ok = false;
   //--- Если объёмы равны — закрываем хедж целиком
   if(MathAbs(hvol - bestVol) < 1e-9)
     {
      Trade.SetExpertMagicNumber(HedgeMagic());
      ok = Trade.PositionClose(hticket);
      Trade.SetExpertMagicNumber(InpMagic);
     }
   else
     {
      Trade.SetExpertMagicNumber(HedgeMagic());
      ok = Trade.PositionClosePartial(hticket, NormalizeLot(bestVol));
      Trade.SetExpertMagicNumber(InpMagic);
     }
   if(!ok)
     {
      PrintFormat("[DDRescue] UNLOCK pair: hedge close (vol=%.2f) failed: %s. "
                  "ВНИМАНИЕ: корзинная позиция уже закрыта, хедж не уменьшен.",
                  bestVol, Trade.ResultRetcodeDescription());
      return true; // корзинную закрыли, парность нарушена — но это не убыток,
                   // т.к. на следующем тике алгоритм снова попробует закрыть хедж.
     }

   PrintFormat("[DDRescue] UNLOCK PAIR: basket #%I64u (PnL=%.2f, vol=%.2f) + hedge %.2f лот (PnL part≈%.2f). Net pair PnL>=%.2f",
               bestTk, bestPL, bestVol, bestVol, hpl * (bestVol/hvol), bestPL + hpl * (bestVol/hvol));
   return true;
  }

//--- Найти позицию-цель для частичного закрытия. side: +1=среди Buy, -1=среди Sell, 0=любая
//    Если InpPartialOnlyProfitable=true — рассматриваются только позиции в плюсе.
ulong PickPartialCloseTicket(const int side)
  {
   ulong best = 0;
   double bestVol = 0.0;
   double bestLoss = DBL_MAX; // самый отрицательный PnL
   double bestProfit = -DBL_MAX; // самый положительный PnL
   datetime bestFirst = D'2099.01.01';
   datetime bestLast  = 0;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      if(!Pos.SelectByIndex(i)) continue;
      if(Pos.Symbol() != _Symbol) continue;
      bool ours   = (Pos.Magic() == InpMagic);
      bool manual = (Pos.Magic() != InpMagic && Pos.Magic() != HedgeMagic());
      if(!ours && !(InpManageManualTrades && manual)) continue;

      int psd = (Pos.PositionType() == POSITION_TYPE_BUY) ? +1 : -1;
      if(side != 0 && psd != side) continue;

      double vol = Pos.Volume();
      double pl  = Pos.Profit() + Pos.Swap() + Pos.Commission();
      datetime t = (datetime)Pos.Time();
      ulong tk   = Pos.Ticket();

      //--- (правка) фильтр «не закрывать в убыток»
      if(InpPartialOnlyProfitable && pl < 0.0) continue;

      switch(InpPartialTarget)
        {
         case PCT_LARGEST_LOT:
            if(vol > bestVol) { bestVol = vol; best = tk; }
            break;
         case PCT_BIGGEST_LOSS:
            //--- осмысленно только если InpPartialOnlyProfitable=false
            if(pl < bestLoss) { bestLoss = pl; best = tk; }
            break;
         case PCT_FIRST_OPENED:
            if(t < bestFirst) { bestFirst = t; best = tk; }
            break;
         case PCT_LAST_OPENED:
            if(t > bestLast)  { bestLast = t; best = tk; }
            break;
         case PCT_BIGGEST_PROFIT:
            if(pl > bestProfit) { bestProfit = pl; best = tk; }
            break;
        }
     }
   return best;
  }

//--- Решение о частичном закрытии и его исполнение
void TryPartialClose(const BasketInfo &b)
  {
   if(!InpUsePartialClose) return;
   if(g_hedgeActive) return; // во время хедж-лока работает unlock-логика
   int total = b.buyCount + b.sellCount;
   if(total < InpPartialMinAverages + 1) return;
   if(g_basketPeakDD < InpPartialMinDDPct) return;
   if(InpPartialCooldownSec > 0
      && g_lastPartialCloseTime > 0
      && (TimeCurrent() - g_lastPartialCloseTime) < InpPartialCooldownSec) return;

   double balance = Acc.Balance();
   double equity  = Acc.Equity();
   double ddPct   = (balance > 0.0) ? (balance - equity) * 100.0 / balance : 0.0;
   if(g_basketPeakDD <= 0.0) return;
   double recovered = (g_basketPeakDD - ddPct) * 100.0 / g_basketPeakDD;
   if(recovered < InpPartialRecoveryPct) return;

   // Закрываем по «трапнутой» стороне (где больше убытка); если стороны равны — любую
   int side = 0;
   if(b.buyCount > 0 && b.sellCount == 0) side = +1;
   else if(b.sellCount > 0 && b.buyCount == 0) side = -1;
   else
     {
      // выберем сторону с большим лотом — там обычно больше убытка
      side = (b.buyLots >= b.sellLots) ? +1 : -1;
     }

   ulong tk = PickPartialCloseTicket(side);
   //--- (правка) если в выбранной стороне нет подходящей позиции (например,
   //    InpPartialOnlyProfitable=true и все убыточные) — пробуем противоположную
   if(tk == 0 && side != 0) tk = PickPartialCloseTicket(-side);
   //--- ...и в крайнем случае — любую
   if(tk == 0)              tk = PickPartialCloseTicket(0);
   if(tk == 0) return;
   if(Trade.PositionClose(tk))
     {
      g_lastPartialCloseTime = TimeCurrent();
      // После частичного закрытия сбрасываем пик DD — теперь корзина «легче»
      g_basketPeakDD = ddPct;
      PrintFormat("[DDRescue] PARTIAL CLOSE ticket=%I64u side=%s recovered=%.2f%% peakDD=%.2f%%",
                  tk, (side > 0) ? "BUY" : "SELL", recovered, g_basketPeakDD);
     }
   else
     {
      PrintFormat("[DDRescue] PARTIAL CLOSE failed ticket=%I64u: %s",
                  tk, Trade.ResultRetcodeDescription());
     }
  }

//================== Дашборд ========================================
void UpdateDashboard(const BasketInfo &b)
  {
   if(!InpShowDashboard)
     {
      if(ObjectFind(0, DASH_NAME) >= 0) ObjectDelete(0, DASH_NAME);
      return;
     }
   double balance = Acc.Balance();
   double equity  = Acc.Equity();
   double ddPct   = (balance > 0.0) ? (balance - equity) * 100.0 / balance : 0.0;
   double atr     = GetATR();
   double step    = GridStepPrice();
   int trend      = GetTrendSide();
   string trendTxt = (trend > 0) ? "Up" : (trend < 0) ? "Dn" : "--";

   string txt = StringFormat(
      "DDRescue v1.20\n"
      "Balance: %.2f  Equity: %.2f  DD: %.2f%%  PeakDD: %.2f%%\n"
      "Buy: %d (%.2f lot @ %.*f)   Sell: %d (%.2f lot @ %.*f)\n"
      "Floating: %.2f  Trend: %s  ATR: %.*f  Step: %.*f\n"
      "Hedge: %s  EquityStop: %s  DailyLimit: %s",
      balance, equity, ddPct, g_basketPeakDD,
      b.buyCount, b.buyLots, _Digits, b.buyVwap,
      b.sellCount, b.sellLots, _Digits, b.sellVwap,
      b.floatingPL, trendTxt, _Digits, atr, _Digits, step,
      g_hedgeActive
         ? StringFormat("%s %.2f", (g_hedgeSide > 0) ? "BUY" : "SELL", g_hedgeLot)
         : "off",
      g_equityStopHit ? "HIT" : "ok",
      g_dailyLimitHit ? "HIT" : "ok");

   if(ObjectFind(0, DASH_NAME) < 0)
     {
      ObjectCreate(0, DASH_NAME, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, DASH_NAME, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
      ObjectSetInteger(0, DASH_NAME, OBJPROP_XDISTANCE, 12);
      ObjectSetInteger(0, DASH_NAME, OBJPROP_YDISTANCE, 24);
      ObjectSetInteger(0, DASH_NAME, OBJPROP_FONTSIZE,  9);
      ObjectSetString (0, DASH_NAME, OBJPROP_FONT,      "Consolas");
      ObjectSetInteger(0, DASH_NAME, OBJPROP_COLOR,     clrSilver);
      ObjectSetInteger(0, DASH_NAME, OBJPROP_HIDDEN,    true);
      ObjectSetInteger(0, DASH_NAME, OBJPROP_BACK,      false);
      ObjectSetInteger(0, DASH_NAME, OBJPROP_SELECTABLE,false);
     }
   ObjectSetString(0, DASH_NAME, OBJPROP_TEXT, txt);
   color clr = (ddPct >= InpEquityStopPct * 0.7) ? clrTomato
             : (ddPct >= InpDrawdownStartPct)    ? clrGold
             : clrLightGreen;
   ObjectSetInteger(0, DASH_NAME, OBJPROP_COLOR, clr);
  }

//================== События ========================================
int OnInit()
  {
   if(!Sym.Name(_Symbol))
     {
      Print("[DDRescue] Не удалось инициализировать SymbolInfo");
      return INIT_FAILED;
     }
   Sym.Refresh();
   Sym.RefreshRates();

   Trade.SetExpertMagicNumber(InpMagic);
   Trade.SetMarginMode();
   Trade.SetTypeFillingBySymbol(_Symbol);
   Trade.SetDeviationInPoints(20);

   g_pip = PipSize();
   g_pipDigits = (g_pip > _Point + 1e-12) ? 1 : 0;

   g_atrHandle    = iATR(_Symbol, InpATRTimeframe, InpATRPeriod);
   g_emaFastHandle = iMA(_Symbol, InpTrendTF, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_emaSlowHandle = iMA(_Symbol, InpTrendTF, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(g_atrHandle == INVALID_HANDLE || g_emaFastHandle == INVALID_HANDLE || g_emaSlowHandle == INVALID_HANDLE)
     {
      Print("[DDRescue] Не удалось создать индикаторы");
      return INIT_FAILED;
     }

   //--- (v1.10) iCustom EvasiveST_FBG — нужен только если выбран FBG-триггер.
   //    Используем дефолтные параметры индикатора. Если хотите собственные —
   //    добавьте их явно после имени файла (см. документацию iCustom).
   if(InpEntryTrigger != TRG_EMA)
     {
      g_fbgHandle = iCustom(_Symbol, _Period, InpFBGIndicator);
      if(g_fbgHandle == INVALID_HANDLE)
        {
         PrintFormat("[DDRescue] iCustom('%s') failed, err=%d. "
                     "Положите %s.ex5 в MQL5/Indicators и перекомпилируйте.",
                     InpFBGIndicator, GetLastError(), InpFBGIndicator);
         return INIT_FAILED;
        }
     }

   RolloverDailyState();
   //--- (v1.10) Восстановим состояние хеджа после рестарта
   RefreshHedgeState();
   PrintFormat("[DDRescue] Старт. Symbol=%s Digits=%d Pip=%.*f Magic=%I64d HedgeMagic=%I64d EntryTrig=%s",
               _Symbol, _Digits, _Digits, g_pip, InpMagic, HedgeMagic(),
               EnumToString(InpEntryTrigger));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(g_atrHandle    != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_emaFastHandle != INVALID_HANDLE) IndicatorRelease(g_emaFastHandle);
   if(g_emaSlowHandle != INVALID_HANDLE) IndicatorRelease(g_emaSlowHandle);
   if(g_fbgHandle    != INVALID_HANDLE) IndicatorRelease(g_fbgHandle);
   if(ObjectFind(0, DASH_NAME) >= 0) ObjectDelete(0, DASH_NAME);
  }

void OnTick()
  {
   Sym.RefreshRates();
   RolloverDailyState();

   BasketInfo b;
   GetBasket(b);

   //--- (v1.10) Обновим состояние хеджа и пиковую просадку корзины
   RefreshHedgeState();
   {
      double balance = Acc.Balance();
      double equity  = Acc.Equity();
      double ddPct = (balance > 0.0) ? (balance - equity) * 100.0 / balance : 0.0;
      // Пик DD ведём только пока есть позиции; после полного закрытия — обнуляется
      if(b.buyCount + b.sellCount == 0) g_basketPeakDD = 0.0;
      else if(ddPct > g_basketPeakDD)   g_basketPeakDD = ddPct;
   }

   //--- Предохранители (даже если EquityStop уже сработал — мониторим)
   if(CheckEquityStop()) { UpdateDashboard(b); return; }
   if(CheckFridayClose()){ UpdateDashboard(b); return; }
   CheckDailyLoss();

   //--- Закрытие корзины при достижении целевой прибыли или брэйк-ивена
   if(b.buyCount + b.sellCount > 0)
     {
      //--- (v1.20) При активном хедже учитываем его PnL: суммарный результат
      //    закрытия (корзина + хедж) должен быть не хуже целевого, иначе
      //    держим лок (хедж может быть в минусе и съесть весь TP корзины).
      double hpl_chk=0.0; double hv_chk=0.0; int hs_chk=0;
      if(g_hedgeActive) GetHedgeTicket(hpl_chk, hv_chk, hs_chk);
      double combinedPL = b.floatingPL + hpl_chk;

      if(BasketHitTarget(b) && (!g_hedgeActive || combinedPL >= TargetMoney(b)))
        {
         if(InpVerboseLog) Print("[DDRescue] TP корзины достигнут — закрываю всё");
         CloseAllOurs("basket-tp");
         CloseAllHedges("basket-tp");
         GetBasket(b);
         UpdateDashboard(b);
         return;
        }
      if(BasketHitBreakeven(b) && (!g_hedgeActive || combinedPL >= 0.0))
        {
         if(InpVerboseLog) Print("[DDRescue] Брэйк-ивен достигнут — закрываю всё");
         CloseAllOurs("breakeven");
         CloseAllHedges("breakeven");
         GetBasket(b);
         UpdateDashboard(b);
         return;
        }
     }

   //--- (v1.20) Парное расколачивание лока: закрываем хедж и корзинную позицию
   //    парами так, чтобы сумма пары была неотрицательной. Запускается при
   //    активном хедже до проверки полного снятия — даёт шанс выйти из лока
   //    постепенно без реализации убытков.
   if(g_hedgeActive)
     {
      if(TryUnlockPair())
        {
         RefreshHedgeState();
         GetBasket(b);
        }
     }

   //--- (v1.10) Хедж-лок: расколачивание (закрываем хедж первым при восстановлении)
   if(g_hedgeActive && ShouldUnlockHedge())
     {
      Print("[DDRescue] Снятие хеджа: цена откатилась, восстановление достигнуто");
      CloseAllHedges("unlock");
      RefreshHedgeState();
      // После снятия хеджа сбросим пик DD корзины — теперь работаем «по-новой»
      double balance = Acc.Balance();
      double equity  = Acc.Equity();
      g_basketPeakDD = (balance > 0.0) ? (balance - equity) * 100.0 / balance : 0.0;
     }

   //--- (v1.10) Хедж-лок: открытие при глубокой просадке
   if(InpUseHedgeLock && !g_hedgeActive)
     {
      int trapped = 0;
      if(ShouldOpenHedge(b, trapped) && trapped != 0)
        {
         double hlot = HedgeLotFor(trapped, b);
         // Хедж в противоположную сторону
         if(OpenHedge(-trapped, hlot)) RefreshHedgeState();
        }
     }

   //--- (v1.10) Частичное закрытие на откате
   TryPartialClose(b);
   GetBasket(b);

   //--- Если активен глобальный запрет — выходим из логики открытий
   if(g_equityStopHit) { UpdateDashboard(b); return; }
   if(g_dailyLimitHit && InpDisableAfterLimit) { UpdateDashboard(b); return; }

   //--- Открытие сделок только при нормальном спреде
   if(!SpreadOk()) { UpdateDashboard(b); return; }

   //--- Усреднение существующих позиций
   //    BUY: если есть buy и цена ушла вниз на >= step
   if(b.buyCount > 0 && ShouldAverage(+1, b))
     {
      double lot = LotForOrder(b.buyCount + 1);
      OpenMarket(+1, lot, StringFormat("avg-buy#%d", b.buyCount + 1));
      GetBasket(b);
     }
   if(b.sellCount > 0 && ShouldAverage(-1, b))
     {
      double lot = LotForOrder(b.sellCount + 1);
      OpenMarket(-1, lot, StringFormat("avg-sell#%d", b.sellCount + 1));
      GetBasket(b);
     }

   //--- Первый вход (если включён авто-режим и нет позиций нашего магика на стороне)
   //    При активном хедже новых первых входов не делаем.
   if(InpAutoTradeFirst && !g_hedgeActive)
     {
      // Не торгуем, если уже есть позиции (включая ручные при manage=on)
      bool noBuys  = (b.buyCount  == 0);
      bool noSells = (b.sellCount == 0);
      int side = AllowedSide();
      if(side != 0)
        {
         double lot = LotForOrder(1);
         if(InpDirection == RDIR_BOTH)
           {
            if(noBuys)  OpenMarket(+1, lot, "init-buy");
            if(noSells) OpenMarket(-1, lot, "init-sell");
           }
         else
           {
            if(side > 0 && noBuys)  OpenMarket(+1, lot, "init-buy");
            if(side < 0 && noSells) OpenMarket(-1, lot, "init-sell");
           }
        }
     }

   GetBasket(b);
   UpdateDashboard(b);
  }
//+------------------------------------------------------------------+
