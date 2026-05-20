//+------------------------------------------------------------------+
//|                                       XAU_Scalper_Aggressive.mq5 |
//|                  Агрессивный скальпер по золоту (XAUUSD) для MT5 |
//|                                                                  |
//|  ВНИМАНИЕ:                                                       |
//|  Параметры по умолчанию рассчитаны на максимально агрессивную    |
//|  торговлю (мартингейл, отсутствие стоп-лосса по умолчанию,       |
//|  возможность сеточных доборов, вход на каждом тике).             |
//|  Такая конфигурация способна слить депозит за одну неудачную     |
//|  серию. Перед использованием на реальном счёте обязательно       |
//|  тестируйте на демо и подбирайте параметры под свой риск.        |
//|                                                                  |
//|  Стратегия:                                                      |
//|   • Таймфрейм рекомендован M1 (true scalping). Допустимы M5/M15. |
//|   • Сигнал BUY:  цена бьёт нижнюю Bollinger Band И RSI < OS.     |
//|     Опционально: цена выше EMA-фильтра тренда.                   |
//|   • Сигнал SELL: симметрично (верхняя BB + RSI > OB).            |
//|   • Тейк короткий (по умолчанию 80 пунктов цены = $0.80).        |
//|   • SL по умолчанию выключен, есть опциональный страхующий SL    |
//|     и принудительный аварийный «капитальный» стоп (% от баланса).|
//|   • Trailing stop + breakeven.                                   |
//|   • Мартингейл: после убытка следующий лот x N (с потолком).     |
//|   • Сетка: можно держать несколько одновременных позиций.        |
//|   • Жёсткий фильтр спреда (для XAUUSD это критично).             |
//|   • Фильтр торговых часов.                                       |
//+------------------------------------------------------------------+
#property copyright "Kiro"
#property version   "1.00"
#property description "Агрессивный M1-скальпер для XAUUSD: BB+RSI+EMA, мартингейл, трейлинг"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//================== Перечисления =====================================
enum ENUM_LOT_MODE
  {
   LOT_FIXED       = 0, // Фиксированный лот
   LOT_RISK_PCT    = 1, // % от баланса на сделку (через SL)
   LOT_MARTINGALE  = 2  // Базовый лот + мартингейл после убытка
  };

//================== Входные параметры ================================
input group "=== Общие настройки ==="
input long             InpMagic            = 20260519;     // Magic number
input string           InpComment          = "XAU-Scalper"; // Комментарий к ордерам
input int              InpSlippagePoints   = 30;            // Допустимое проскальзывание (пункты)
input bool             InpAllowOnNewBarOnly= false;         // Сигналы только на закрытии бара (иначе — каждый тик)

input group "=== Управление лотом ==="
input ENUM_LOT_MODE    InpLotMode          = LOT_MARTINGALE;// Режим расчёта лота
input double           InpLotFixed         = 0.01;          // Базовый/фиксированный лот
input double           InpRiskPercent      = 1.0;           // Риск на сделку, % от баланса (для LOT_RISK_PCT)
input int              InpRiskCalcSLPts    = 300;           // Виртуальный SL для расчёта риск-лота (пункты). 0 = брать InpStopLossPts
input double           InpMartingaleMult   = 2.0;           // Множитель лота после убытка
input double           InpMartingaleMaxLot = 1.00;          // Максимальный лот при мартингейле
input int              InpMaxLossesInRow   = 6;             // После N убытков подряд — сброс лота к базовому
input bool             InpGridMartingale   = true;          // Сеточный мартингейл: каждый новый ордер в открытой сетке с увеличенным лотом
input bool             InpGridFromBaseLot  = true;          // База для сеточного мартингейла: true=InpLotFixed, false=текущий g_currentLot
input int              InpGridStepOrders   = 1;             // Шаг увеличения лота: умножать каждые N ордеров сетки (1=каждый ордер, 2=каждый 2-й, ...)

input group "=== Цели и защита ==="
input int              InpTakeProfitPts    = 80;            // Тейк-профит (в пунктах цены, 1 пункт=_Point)
input int              InpStopLossPts      = 0;             // Стоп-лосс (0 — без SL)
input bool             InpUseTotalTP       = true;          // Общий тейк-профит (по суммарной прибыли всех позиций)
input double           InpTotalTPMoney     = 5.0;           // Целевая суммарная прибыль (валюта счёта) для закрытия всех
input bool             InpTotalTPResetMart = true;          // Сброс мартингейла после общего тейка
input bool             InpUseEquityStop    = true;          // Аварийный стоп по эквити
input double           InpEquityStopPct    = 25.0;          // Просадка эквити, % от баланса — закрыть всё

input group "=== Трейлинг и безубыток ==="
input bool             InpUseBreakeven     = true;          // Перевод в безубыток
input int              InpBreakevenAfterPts= 40;            // После какой прибыли (пункты) переводить в БУ
input int              InpBreakevenOffsetPts = 5;           // Сдвиг БУ за вход (пункты)
input bool             InpUseTrailing      = true;          // Трейлинг-стоп
input int              InpTrailingStartPts = 60;            // Активировать трейлинг после прибыли (пункты)
input int              InpTrailingStepPts  = 30;            // Шаг трейлинга (пункты)
input int              InpTrailingDistPts  = 50;            // Дистанция трейлинга от цены (пункты)

input group "=== Сетка / частота ==="
input int              InpMaxPositions     = 3;             // Макс. число одновременных позиций (1 = без сетки)
input int              InpMinSecBetweenOrders = 2;          // Минимум секунд между входами

input group "=== Сигналы (BB + RSI + EMA) ==="
input int              InpBBPeriod         = 20;            // Период Bollinger Bands
input double           InpBBDeviation      = 2.0;           // Отклонение BB
input int              InpRSIPeriod        = 7;             // Период RSI (короткий — для скальпа)
input double           InpRSIOversold      = 25.0;          // Уровень перепроданности
input double           InpRSIOverbought    = 75.0;          // Уровень перекупленности
input bool             InpUseTrendFilter   = false;         // Фильтр тренда по EMA (агрессивно — выкл.)
input int              InpEMAPeriod        = 50;            // Период EMA-фильтра

input group "=== Фильтр спреда ==="
input int              InpMaxSpreadPts     = 35;            // Макс. допустимый спред (пункты). Для XAUUSD типично 20-30

input group "=== Фильтр времени (по серверному времени брокера) ==="
input bool             InpUseTimeFilter    = true;          // Включить фильтр часов
input int              InpHourStart        = 8;             // Час начала торговли (включительно)
input int              InpHourEnd          = 21;            // Час окончания (исключительно)
input bool             InpTradeMonday      = true;
input bool             InpTradeFriday      = true;          // На пятницу часто отключают вечер
input int              InpFridayStopHour   = 20;            // В пятницу стоп торговли с этого часа

//================== Глобальные объекты ===============================
CTrade            g_trade;
CPositionInfo     g_pos;
CSymbolInfo       g_sym;

int               g_hBB    = INVALID_HANDLE;
int               g_hRSI   = INVALID_HANDLE;
int               g_hEMA   = INVALID_HANDLE;

datetime          g_lastBarTime  = 0;
datetime          g_lastOrderTime= 0;

double            g_currentLot   = 0.0;   // следующий лот для мартингейла
int               g_lossStreak   = 0;
ulong             g_lastClosedDeal = 0;   // для отслеживания закрытых сделок

double            g_equityPeak   = 0.0;   // для аварийного стопа

//+------------------------------------------------------------------+
//| Утилиты                                                          |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
  {
   double minL  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = 0.01;
   lot = MathMax(minL, MathMin(maxL, lot));
   lot = MathFloor(lot / step + 0.5) * step;
   return NormalizeDouble(lot, 2);
  }

double PointsToPrice(int pts)
  {
   return pts * _Point;
  }

int PriceToPoints(double dp)
  {
   if(_Point <= 0.0) return 0;
   return (int)MathRound(dp / _Point);
  }

int CurrentSpreadPts()
  {
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t)) return INT_MAX;
   return (int)MathRound((t.ask - t.bid) / _Point);
  }

bool IsNewBar()
  {
   datetime tcur = iTime(_Symbol, _Period, 0);
   if(tcur != g_lastBarTime)
     {
      g_lastBarTime = tcur;
      return true;
     }
   return false;
  }

bool TimeAllowed()
  {
   if(!InpUseTimeFilter) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   // Воскресенье (0) и суббота (6) — биржа золота закрыта
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;
   if(dt.day_of_week == 1 && !InpTradeMonday) return false;
   if(dt.day_of_week == 5)
     {
      if(!InpTradeFriday) return false;
      if(dt.hour >= InpFridayStopHour) return false;
     }
   if(dt.hour < InpHourStart || dt.hour >= InpHourEnd) return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Подсчёт открытых позиций по символу и magic                      |
//+------------------------------------------------------------------+
int CountMyPositions(int &buyCnt, int &sellCnt)
  {
   buyCnt = 0; sellCnt = 0;
   int total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      if(!g_pos.SelectByIndex(i)) continue;
      if(g_pos.Symbol() != _Symbol) continue;
      if(g_pos.Magic()  != InpMagic) continue;
      total++;
      if(g_pos.PositionType() == POSITION_TYPE_BUY) buyCnt++;
      else if(g_pos.PositionType() == POSITION_TYPE_SELL) sellCnt++;
     }
   return total;
  }

//+------------------------------------------------------------------+
//| Расчёт лота                                                      |
//|   openSameSide — сколько уже открыто позиций EA в ту же сторону, |
//|   что и планируемый ордер. Используется для сеточного мартингейла|
//+------------------------------------------------------------------+
double CalcLot(int openSameSide = 0)
  {
   double lot = InpLotFixed;
   switch(InpLotMode)
     {
      case LOT_FIXED:
         lot = InpLotFixed;
         break;

      case LOT_RISK_PCT:
        {
         // Используем отдельный «виртуальный SL» для расчёта риска,
         // чтобы режим работал даже когда реальный InpStopLossPts == 0.
         int slForCalc = (InpRiskCalcSLPts > 0) ? InpRiskCalcSLPts : InpStopLossPts;
         if(slForCalc <= 0)
           {
            static bool warnedNoSL = false;
            if(!warnedNoSL)
              {
               Print("[Scalper] LOT_RISK_PCT: задайте InpRiskCalcSLPts > 0 (или InpStopLossPts > 0) "
                     "для расчёта лота по риску. Сейчас фолбэк на InpLotFixed.");
               warnedNoSL = true;
              }
            lot = InpLotFixed;
            break;
           }
         double balance = AccountInfoDouble(ACCOUNT_BALANCE);
         double riskMoney = balance * InpRiskPercent / 100.0;
         double tickVal   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
         double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
         if(tickSize <= 0.0 || tickVal <= 0.0)
           {
            PrintFormat("[Scalper] LOT_RISK_PCT: некорректные tickSize=%.5f tickVal=%.5f, фолбэк на InpLotFixed",
                        tickSize, tickVal);
            lot = InpLotFixed;
            break;
           }
         double slPrice    = slForCalc * _Point;
         double lossPerLot = (slPrice / tickSize) * tickVal;
         if(lossPerLot <= 0.0) { lot = InpLotFixed; break; }
         lot = riskMoney / lossPerLot;

         // Лог расчёта не чаще раза в 5 минут — иначе зальёт журнал
         static datetime lastRiskLog = 0;
         if(TimeCurrent() - lastRiskLog > 300)
           {
            PrintFormat("[Scalper] Риск-лот: bal=%.2f, риск=%.2f%% (%.2f %s), "
                        "SL_calc=%dpts, потеря/лот=%.2f, лот=%.2f",
                        balance, InpRiskPercent, riskMoney,
                        AccountInfoString(ACCOUNT_CURRENCY),
                        slForCalc, lossPerLot, lot);
            lastRiskLog = TimeCurrent();
           }
         break;
        }

      case LOT_MARTINGALE:
         if(g_currentLot <= 0.0) g_currentLot = InpLotFixed;
         lot = g_currentLot;

         // Сеточный мартингейл: множитель ^ (число уже открытых позиций той же стороны).
         // Работает даже без SL — лот растёт по мере добора сетки.
         // InpGridStepOrders регулирует шаг прогрессии: при step=N лот умножается
         // только каждые N ордеров (степень = floor(openSameSide / step)).
         if(InpGridMartingale && openSameSide > 0)
           {
            double base = InpGridFromBaseLot ? InpLotFixed : g_currentLot;
            int    step = (InpGridStepOrders > 0) ? InpGridStepOrders : 1;
            int    expN = openSameSide / step; // целочисленное деление = floor
            double mult = MathPow(InpMartingaleMult, (double)expN);
            lot = base * mult;
            if(lot > InpMartingaleMaxLot) lot = InpMartingaleMaxLot;
            PrintFormat("[Scalper] Сеточный мартингейл: уже открыто %d, шаг=%d, степень=%d, "
                        "база=%.2f x %.2f^%d -> %.2f",
                        openSameSide, step, expN, base, InpMartingaleMult, expN, lot);
           }
         break;
     }
   return NormalizeLot(lot);
  }

//+------------------------------------------------------------------+
//| Обновление мартингейла после закрытия сделки                     |
//+------------------------------------------------------------------+
void UpdateMartingaleFromHistory()
  {
   if(InpLotMode != LOT_MARTINGALE) return;

   if(!HistorySelect(TimeCurrent() - 7*24*3600, TimeCurrent() + 60))
      return;

   int total = HistoryDealsTotal();
   ulong newestDeal = 0;
   double newestProfit = 0.0;
   datetime newestTime = 0;

   for(int i = total - 1; i >= 0; --i)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if((string)HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if((long)HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagic) continue;
      if((int)HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

      datetime t = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
      if(t > newestTime)
        {
         newestTime = t;
         newestDeal = ticket;
         newestProfit = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                      + HistoryDealGetDouble(ticket, DEAL_SWAP)
                      + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
        }
     }

   if(newestDeal == 0 || newestDeal == g_lastClosedDeal) return;
   g_lastClosedDeal = newestDeal;

   if(newestProfit < 0.0)
     {
      g_lossStreak++;
      if(g_lossStreak >= InpMaxLossesInRow)
        {
         g_currentLot = InpLotFixed;
         g_lossStreak = 0;
         PrintFormat("[Scalper] Достигнут предел убытков подряд (%d). Сброс лота к базовому %.2f",
                     InpMaxLossesInRow, InpLotFixed);
        }
      else
        {
         g_currentLot = NormalizeLot(g_currentLot * InpMartingaleMult);
         if(g_currentLot > InpMartingaleMaxLot)
            g_currentLot = NormalizeLot(InpMartingaleMaxLot);
         PrintFormat("[Scalper] Убыток %.2f, новый лот %.2f (серия %d)",
                     newestProfit, g_currentLot, g_lossStreak);
        }
     }
   else
     {
      g_currentLot = InpLotFixed;
      g_lossStreak = 0;
     }
  }

//+------------------------------------------------------------------+
//| Получение значений индикаторов                                   |
//+------------------------------------------------------------------+
bool ReadSignals(double &bbUpper, double &bbLower, double &bbMid,
                 double &rsi, double &ema, double &closePrev)
  {
   double up[], lo[], md[], r[], e[];
   ArraySetAsSeries(up, true);
   ArraySetAsSeries(lo, true);
   ArraySetAsSeries(md, true);
   ArraySetAsSeries(r,  true);
   ArraySetAsSeries(e,  true);

   // BB: 0=middle, 1=upper, 2=lower (стандартное распределение в MT5)
   if(CopyBuffer(g_hBB, 1, 0, 2, up) < 2) return false;
   if(CopyBuffer(g_hBB, 2, 0, 2, lo) < 2) return false;
   if(CopyBuffer(g_hBB, 0, 0, 2, md) < 2) return false;
   if(CopyBuffer(g_hRSI,0, 0, 2, r)  < 2) return false;

   if(InpUseTrendFilter)
     {
      if(g_hEMA == INVALID_HANDLE) return false;
      if(CopyBuffer(g_hEMA, 0, 0, 2, e) < 2) return false;
      ema = e[0];
     }
   else
     {
      ema = 0.0;
     }

   bbUpper = up[0];
   bbLower = lo[0];
   bbMid   = md[0];
   rsi     = r[0];

   double cls[];
   ArraySetAsSeries(cls, true);
   if(CopyClose(_Symbol, _Period, 0, 2, cls) < 2) return false;
   closePrev = cls[1];
   return true;
  }

//+------------------------------------------------------------------+
//| Решение о входе                                                  |
//|   1 = BUY, -1 = SELL, 0 = ничего                                 |
//+------------------------------------------------------------------+
int SignalDirection()
  {
   double bbU, bbL, bbM, rsi, ema, prevClose;
   if(!ReadSignals(bbU, bbL, bbM, rsi, ema, prevClose)) return 0;

   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t)) return 0;
   double bid = t.bid;
   double ask = t.ask;

   bool buyTrigger  = (bid <= bbL) && (rsi <= InpRSIOversold);
   bool sellTrigger = (ask >= bbU) && (rsi >= InpRSIOverbought);

   if(InpUseTrendFilter)
     {
      buyTrigger  = buyTrigger  && (bid > ema);
      sellTrigger = sellTrigger && (ask < ema);
     }

   if(buyTrigger && !sellTrigger)  return  1;
   if(sellTrigger && !buyTrigger)  return -1;
   return 0;
  }

//+------------------------------------------------------------------+
//| Открытие позиции                                                 |
//|   openSameSide — сколько уже открыто позиций EA той же стороны   |
//|   (для прогрессивного/сеточного мартингейла)                     |
//+------------------------------------------------------------------+
bool OpenPosition(int dir, int openSameSide = 0)
  {
   if(!g_sym.RefreshRates()) return false;
   double lot = CalcLot(openSameSide);
   if(lot <= 0.0) return false;

   // Явный лог режима лота — чтобы было видно, что мартингейл/риск работают.
   static int logCount = 0;
   if(logCount < 5 || (logCount % 20) == 0)
     {
      string mode = (InpLotMode == LOT_FIXED)      ? "FIXED"
                  : (InpLotMode == LOT_RISK_PCT)   ? "RISK_PCT"
                  : "MARTINGALE";
      PrintFormat("[Scalper] CalcLot[%s, sameSide=%d] -> %.2f (база=%.2f, текущ.мартингейл=%.2f, серия убытков=%d, gridMart=%s)",
                  mode, openSameSide, lot, InpLotFixed, g_currentLot, g_lossStreak,
                  (InpGridMartingale ? "ON" : "OFF"));
     }
   logCount++;

   double price = (dir > 0) ? g_sym.Ask() : g_sym.Bid();
   double sl    = 0.0;
   double tp    = 0.0;

   if(InpStopLossPts > 0)
      sl = (dir > 0) ? price - PointsToPrice(InpStopLossPts)
                     : price + PointsToPrice(InpStopLossPts);
   if(InpTakeProfitPts > 0)
      tp = (dir > 0) ? price + PointsToPrice(InpTakeProfitPts)
                     : price - PointsToPrice(InpTakeProfitPts);

   sl = (sl > 0.0) ? NormalizeDouble(sl, _Digits) : 0.0;
   tp = (tp > 0.0) ? NormalizeDouble(tp, _Digits) : 0.0;

   bool ok = false;
   if(dir > 0)
      ok = g_trade.Buy(lot, _Symbol, 0.0, sl, tp, InpComment);
   else
      ok = g_trade.Sell(lot, _Symbol, 0.0, sl, tp, InpComment);

   if(!ok)
     {
      PrintFormat("[Scalper] Ошибка открытия %s: ret=%u %s",
                  (dir > 0 ? "BUY" : "SELL"),
                  g_trade.ResultRetcode(),
                  g_trade.ResultRetcodeDescription());
      return false;
     }

   g_lastOrderTime = TimeCurrent();
   PrintFormat("[Scalper] %s lot=%.2f @ %.*f  TP=%.*f SL=%.*f",
               (dir > 0 ? "BUY" : "SELL"), lot,
               _Digits, price, _Digits, tp, _Digits, sl);
   return true;
  }

//+------------------------------------------------------------------+
//| Управление открытыми позициями: безубыток + трейлинг             |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   if(!InpUseBreakeven && !InpUseTrailing) return;
   if(!g_sym.RefreshRates()) return;

   double bid = g_sym.Bid();
   double ask = g_sym.Ask();

   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      if(!g_pos.SelectByIndex(i)) continue;
      if(g_pos.Symbol() != _Symbol) continue;
      if(g_pos.Magic()  != InpMagic) continue;

      ulong  ticket = g_pos.Ticket();
      double open   = g_pos.PriceOpen();
      double sl     = g_pos.StopLoss();
      double tp     = g_pos.TakeProfit();
      bool   isBuy  = (g_pos.PositionType() == POSITION_TYPE_BUY);
      double cur    = isBuy ? bid : ask;
      double profitPts = isBuy ? PriceToPoints(cur - open)
                               : PriceToPoints(open - cur);

      double newSL = sl;

      // 1) Безубыток
      if(InpUseBreakeven && profitPts >= InpBreakevenAfterPts)
        {
         double bePrice = isBuy ? open + PointsToPrice(InpBreakevenOffsetPts)
                                : open - PointsToPrice(InpBreakevenOffsetPts);
         if(isBuy)
           {
            if(sl == 0.0 || bePrice > sl) newSL = bePrice;
           }
         else
           {
            if(sl == 0.0 || bePrice < sl) newSL = bePrice;
           }
        }

      // 2) Трейлинг-стоп
      if(InpUseTrailing && profitPts >= InpTrailingStartPts)
        {
         double trailPrice = isBuy ? cur - PointsToPrice(InpTrailingDistPts)
                                   : cur + PointsToPrice(InpTrailingDistPts);
         if(isBuy)
           {
            if(newSL == 0.0 || trailPrice - newSL >= PointsToPrice(InpTrailingStepPts))
               newSL = trailPrice;
           }
         else
           {
            if(newSL == 0.0 || newSL - trailPrice >= PointsToPrice(InpTrailingStepPts))
               newSL = trailPrice;
           }
        }

      if(newSL != sl && newSL > 0.0)
        {
         newSL = NormalizeDouble(newSL, _Digits);
         if(!g_trade.PositionModify(ticket, newSL, tp))
           {
            PrintFormat("[Scalper] PositionModify err: ret=%u %s",
                        g_trade.ResultRetcode(),
                        g_trade.ResultRetcodeDescription());
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Общий тейк-профит: закрытие ВСЕХ позиций по суммарной прибыли   |
//+------------------------------------------------------------------+
bool CheckTotalTakeProfit()
  {
   if(!InpUseTotalTP) return false;

   double totalProfit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      if(!g_pos.SelectByIndex(i)) continue;
      if(g_pos.Symbol() != _Symbol) continue;
      if(g_pos.Magic()  != InpMagic) continue;
      totalProfit += g_pos.Profit() + g_pos.Swap() + g_pos.Commission();
     }

   if(totalProfit >= InpTotalTPMoney)
     {
      // Закрываем все позиции советника
      for(int i = PositionsTotal() - 1; i >= 0; --i)
        {
         if(!g_pos.SelectByIndex(i)) continue;
         if(g_pos.Symbol() != _Symbol) continue;
         if(g_pos.Magic()  != InpMagic) continue;
         g_trade.PositionClose(g_pos.Ticket());
        }
      PrintFormat("[Scalper] ОБЩИЙ ТЕЙК ДОСТИГНУТ: суммарная прибыль %.2f >= %.2f %s. Все позиции закрыты.",
                  totalProfit, InpTotalTPMoney, AccountInfoString(ACCOUNT_CURRENCY));

      // Опционально сбрасываем мартингейл после общего тейка
      if(InpTotalTPResetMart)
        {
         g_currentLot = InpLotFixed;
         g_lossStreak = 0;
        }
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Аварийный «капитальный» стоп                                     |
//+------------------------------------------------------------------+
void EquityGuard()
  {
   if(!InpUseEquityStop) return;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance <= 0.0) return;

   if(equity > g_equityPeak) g_equityPeak = equity;

   double dd = (balance - equity) / balance * 100.0;
   if(dd >= InpEquityStopPct)
     {
      // Закрыть всё своё и заглушить дальнейшую торговлю до перезапуска
      for(int i = PositionsTotal() - 1; i >= 0; --i)
        {
         if(!g_pos.SelectByIndex(i)) continue;
         if(g_pos.Symbol() != _Symbol) continue;
         if(g_pos.Magic()  != InpMagic) continue;
         g_trade.PositionClose(g_pos.Ticket());
        }
      PrintFormat("[Scalper] АВАРИЙНЫЙ СТОП ПО ЭКВИТИ: просадка %.2f%% >= %.2f%%",
                  dd, InpEquityStopPct);
      ExpertRemove();
     }
  }

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!g_sym.Name(_Symbol))
     {
      Print("[Scalper] Не удалось инициализировать SymbolInfo");
      return INIT_FAILED;
     }
   g_sym.RefreshRates();

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetMarginMode();

   g_hBB  = iBands(_Symbol, _Period, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);
   g_hRSI = iRSI  (_Symbol, _Period, InpRSIPeriod, PRICE_CLOSE);
   if(g_hBB == INVALID_HANDLE || g_hRSI == INVALID_HANDLE)
     {
      Print("[Scalper] Ошибка создания BB/RSI");
      return INIT_FAILED;
     }
   if(InpUseTrendFilter)
     {
      g_hEMA = iMA(_Symbol, _Period, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(g_hEMA == INVALID_HANDLE)
        {
         Print("[Scalper] Ошибка создания EMA");
         return INIT_FAILED;
        }
     }

   g_currentLot   = InpLotFixed;
   g_lossStreak   = 0;
   g_equityPeak   = AccountInfoDouble(ACCOUNT_EQUITY);

   // Захватываем ID самой свежей закрытой сделки EA на момент запуска,
   // чтобы НЕ применять мартингейл на основе старой истории.
   g_lastClosedDeal = 0;
   if(HistorySelect(TimeCurrent() - 30*24*3600, TimeCurrent() + 60))
     {
      int htotal = HistoryDealsTotal();
      datetime newestT = 0;
      for(int i = htotal - 1; i >= 0; --i)
        {
         ulong tk = HistoryDealGetTicket(i);
         if(tk == 0) continue;
         if((string)HistoryDealGetString(tk, DEAL_SYMBOL) != _Symbol) continue;
         if((long)HistoryDealGetInteger(tk, DEAL_MAGIC) != InpMagic) continue;
         if((int)HistoryDealGetInteger(tk, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
         datetime t = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
         if(t > newestT) { newestT = t; g_lastClosedDeal = tk; }
        }
     }
   if(InpLotMode == LOT_MARTINGALE)
      PrintFormat("[Scalper] Мартингейл активен: база=%.2f, x%.2f после убытка, потолок=%.2f, "
                  "сброс после %d убытков. Стартовый лот=%.2f",
                  InpLotFixed, InpMartingaleMult, InpMartingaleMaxLot,
                  InpMaxLossesInRow, g_currentLot);

   PrintFormat("[Scalper] Запуск на %s %s. Лот=%.2f, TP=%dpts, SL=%dpts, Spread<=%dpts",
               _Symbol, EnumToString(_Period),
               InpLotFixed, InpTakeProfitPts, InpStopLossPts, InpMaxSpreadPts);

   if(StringFind(_Symbol, "XAU") < 0 && StringFind(_Symbol, "GOLD") < 0)
      PrintFormat("[Scalper] ВНИМАНИЕ: символ %s не похож на золото — параметры подобраны под XAUUSD.",
                  _Symbol);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_hBB  != INVALID_HANDLE) IndicatorRelease(g_hBB);
   if(g_hRSI != INVALID_HANDLE) IndicatorRelease(g_hRSI);
   if(g_hEMA != INVALID_HANDLE) IndicatorRelease(g_hEMA);
  }

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
  {
   // 1) защита эквити — первым делом
   EquityGuard();

   // 1.5) общий тейк-профит — закрыть всё, если цель достигнута
   if(CheckTotalTakeProfit()) return;

   // 2) актуализация мартингейла
   UpdateMartingaleFromHistory();

   // 3) сопровождение открытых позиций
   ManagePositions();

   // 4) гейт «новый бар» (если включён)
   bool newBar = IsNewBar();
   if(InpAllowOnNewBarOnly && !newBar) return;

   // 5) фильтры
   if(!TimeAllowed()) return;

   int spread = CurrentSpreadPts();
   if(spread > InpMaxSpreadPts) return;

   // 6) кулдаун между ордерами
   if(g_lastOrderTime > 0 &&
      (TimeCurrent() - g_lastOrderTime) < InpMinSecBetweenOrders) return;

   // 7) лимит позиций
   int buyCnt = 0, sellCnt = 0;
   int total  = CountMyPositions(buyCnt, sellCnt);
   if(total >= InpMaxPositions) return;

   // 8) сигнал
   int dir = SignalDirection();
   if(dir == 0) return;

   // не множим в ту же сторону без перерыва
   if(dir > 0 && buyCnt  >= InpMaxPositions) return;
   if(dir < 0 && sellCnt >= InpMaxPositions) return;

   // Передаём количество уже открытых позиций той же стороны —
   // прогрессивный/сеточный мартингейл умножит лот на InpMartingaleMult^N.
   int openSameSide = (dir > 0) ? buyCnt : sellCnt;
   OpenPosition(dir, openSameSide);
  }
//+------------------------------------------------------------------+
