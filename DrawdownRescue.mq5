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
//+------------------------------------------------------------------+
#property copyright "Devin"
#property version   "1.00"
#property description "Универсальный советник вытаскивания счёта из просадки (ATR-сетка, корзина TP, предохранители)"
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
input int              InpFastEMA            = 50;           // Быстрая EMA
input int              InpSlowEMA            = 200;          // Медленная EMA
input ENUM_TIMEFRAMES  InpTrendTF            = PERIOD_H1;    // ТФ для EMA-фильтра

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

datetime         g_dayStart = 0;
double           g_dayStartBalance = 0.0;
bool             g_dailyLimitHit = false;
bool             g_equityStopHit = false;

double           g_pip = 0.0;     // размер «пункта трейдера» (с учётом 3/5-знаков)
int              g_pipDigits = 0; // 1 если 3/5-знаков, иначе 0

const string     DASH_NAME = "DDRescue_Dashboard";

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
      bool manual = (Pos.Magic() != InpMagic);
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
      bool manual = (Pos.Magic() != InpMagic);
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

//--- Разрешённое направление по настройкам и тренду
//    Возвращает +1, -1 или 0 (запрещено / нейтрально)
int AllowedSide()
  {
   int trend = GetTrendSide();
   switch(InpDirection)
     {
      case RDIR_BUY_ONLY:  return +1;
      case RDIR_SELL_ONLY: return -1;
      case RDIR_TREND:     return trend;
      case RDIR_COUNTER:   return -trend;
      case RDIR_BOTH:      return (trend == 0) ? +1 : trend;
     }
   return 0;
  }

//--- Условие открытия N-го усреднения для стороны
bool ShouldAverage(const int side, const BasketInfo &b)
  {
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
      "DDRescue v1.00\n"
      "Balance: %.2f  Equity: %.2f  DD: %.2f%%\n"
      "Buy: %d (%.2f lot @ %.*f)   Sell: %d (%.2f lot @ %.*f)\n"
      "Floating: %.2f  Trend: %s  ATR: %.*f  Step: %.*f\n"
      "EquityStop: %s  DailyLimit: %s",
      balance, equity, ddPct,
      b.buyCount, b.buyLots, _Digits, b.buyVwap,
      b.sellCount, b.sellLots, _Digits, b.sellVwap,
      b.floatingPL, trendTxt, _Digits, atr, _Digits, step,
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

   RolloverDailyState();
   PrintFormat("[DDRescue] Старт. Symbol=%s Digits=%d Pip=%.*f Magic=%I64d",
               _Symbol, _Digits, _Digits, g_pip, InpMagic);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(g_atrHandle    != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_emaFastHandle != INVALID_HANDLE) IndicatorRelease(g_emaFastHandle);
   if(g_emaSlowHandle != INVALID_HANDLE) IndicatorRelease(g_emaSlowHandle);
   if(ObjectFind(0, DASH_NAME) >= 0) ObjectDelete(0, DASH_NAME);
  }

void OnTick()
  {
   Sym.RefreshRates();
   RolloverDailyState();

   BasketInfo b;
   GetBasket(b);

   //--- Предохранители (даже если EquityStop уже сработал — мониторим)
   if(CheckEquityStop()) { UpdateDashboard(b); return; }
   if(CheckFridayClose()){ UpdateDashboard(b); return; }
   CheckDailyLoss();

   //--- Закрытие корзины при достижении целевой прибыли или брэйк-ивена
   if(b.buyCount + b.sellCount > 0)
     {
      if(BasketHitTarget(b))
        {
         if(InpVerboseLog) Print("[DDRescue] TP корзины достигнут — закрываю всё");
         CloseAllOurs("basket-tp");
         GetBasket(b);
         UpdateDashboard(b);
         return;
        }
      if(BasketHitBreakeven(b))
        {
         if(InpVerboseLog) Print("[DDRescue] Брэйк-ивен достигнут — закрываю всё");
         CloseAllOurs("breakeven");
         GetBasket(b);
         UpdateDashboard(b);
         return;
        }
     }

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
   if(InpAutoTradeFirst)
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
