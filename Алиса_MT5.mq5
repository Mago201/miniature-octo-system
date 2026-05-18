//+------------------------------------------------------------------+
//|                                             Алиса_MT5.mq5        |
//|   3 стратегии (RSI/WPR/RSI+WPR) + ТРЕНД-ФИЛЬТР + ATR EA          |
//|   Усреднение ТОЛЬКО на новой свече GridTF                        |
//|   + ГЛОБАЛЬНОЕ ЗАКРЫТИЕ ПО ДЕНЬГАМ/ПРОЦЕНТАМ                    |
//|   + ПЕРЕКЛЮЧЕНИЕ РЕЖИМОВ RSI/WPR/СОВМЕСТНО для каждой стратегии |
//|   + ЗАКРЫТИЕ ОРДЕРОВ ПО СМЕНЕ ТРЕНДА                            |
//|   + ЛОКИРОВАНИЕ ПО ПРОСАДКЕ ОТ БАЛАНСА                           |
//|   + RECOVERY HANDOFF (передача DD-корзины советнику Recovery)    |
//|   + SuperTrend LTF+HTF фильтр тренда (v5.3)                     |
//|   + Фильтр новостей через встроенный Calendar (v5.3)             |
//|                                                                  |
//|  v5.2 — фиксы и интеграция:                                      |
//|    A) Один параметр для частичного закрытия (вместо двух).       |
//|    B) Закрытия по тренду/глобалу синхронизируются с локом.       |
//|    C) Лок при OnDeinit закрывается только если CloseLockOnDeinit.|
//|    D) Удаление только своих GUI-объектов (префикс AlicePanel_).  |
//|    E) Не дёргать тренд-смены на самом первом тике (sentinel -2). |
//|    F) Warning при netting + UseDrawdownLock.                     |
//|    G) Max-spread в пипсах вместо magic-числа 10000*Point.        |
//|    H) Чистка handles при провале CGridStrategy::Init.            |
//|    I) Сравнение magic как ulong.                                 |
//|    J) Лог ошибок открытия ордеров.                               |
//|    K) Спред через Refresh + помощник PipSize().                  |
//|    L) Удалён #property strict (MT4).                             |
//|    M) Удалён мёртвый m_signal_type.                              |
//|    N) Удалён неиспользуемый g_global_trade.                      |
//|                                                                  |
//|  RECOVERY HANDOFF (Вариант 2):                                   |
//|    GV "Alisa.Halt"               — 1 пока Алиса в DD-стопе       |
//|    GV "Alisa.AttachEquity"       — equity на момент halt         |
//|    GV "Alisa.Recovery.Active"    — 1 пока Recovery работает      |
//|    Когда UseRecoveryHandoff=true и DD>=HandoffMinDD: Алиса       |
//|    выставляет Halt=1 и засыпает; Recovery подхватывает корзины   |
//|    по магикам Алисы. Возобновление — когда Recovery очистил      |
//|    позиции (Active=0) И DD упала ниже HandoffResumeDD.           |
//|    Старый встречный лок при UseRecoveryHandoff=true отключается. |
//+------------------------------------------------------------------+
#property copyright "АлисА v5.3"
#property link      "ZMA"
#property version   "5.3"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

CAccountInfo   acc;
CSymbolInfo    symb;

string   g_license_gv_name = "Алиса";
int      g_trial_days      = 30;
datetime g_trial_expiry    = 0;
bool     g_license_ok      = true;

bool g_panel_created = false;

input group "=== ОСНОВНЫЕ НАСТРОЙКИ ==="
input string ZMA                = "************ АЛИСА ************"; 
input double НачальныйЛот            = 0.01;
input double РискПроцентов           = 0.0;
input double МножительЛота          = 1.2;
input double ШагСетки               = 800.0;
input double ТейкПрофит             = 300.0;
input double МаксЛот                = 10.0;

input group "=== ТОРГОВЫЕ ФЛАЖКИ ==="
input bool   РазрешитьBuy           = true;
input bool   РазрешитьSell          = true;

input group "=== УПРАВЛЕНИЕ ТРЕНДОМ И ЗАКРЫТИЕМ ==="
input bool   CloseOnTrendChange     = false;   // Закрывать ордера при смене тренда
input bool   CloseBuyOnBearTrend     = false;   // Закрывать BUY при переходе на SELL
input bool   CloseSellOnBullTrend    = false;   // Закрывать SELL при переходе на BUY
input bool   CloseOnFlat             = false;  // Закрывать ВСЕ ордера при ФЛЭТЕ
input bool   ForbidAlisaTradingInFlat = true;  // Запретить торговлю АЛИСЕ во флэте

input group "=== ФИЛЬТР ПО ТРЕНДУ (3 МА) — LEGACY ==="
input bool   UseТрендФильтр         = false;    // [LEGACY] 3-МА фильтр (выключен при UseSTFilter=true)
input ENUM_TIMEFRAMES TrendTF       = PERIOD_H1;
input int    МА_Быстрая             = 133;
input int    МА_Средняя             = 233;
input int    МА_Медленная           = 333;
input ENUM_MA_METHOD МА_Метод       = MODE_EMA;
input ENUM_APPLIED_PRICE МА_Цена    = PRICE_CLOSE;

input group "=== ФИЛЬТР ПО ТРЕНДУ (SuperTrend LTF+HTF) ==="
input bool   UseSTFilter            = true;     // Фильтр по EvasiveST_FBG (заменяет 3 МА)
input string STIndicatorName        = "EvasiveST_FBG"; // Имя индикатора (в Indicators/)
input ENUM_TIMEFRAMES ST_TF         = PERIOD_H1;       // Таймфрейм LTF SuperTrend
input int    STAtrLength            = 10;       // ATR длина (param индикатора)
input double STBaseMultiplier       = 3.0;      // Множитель ATR (param индикатора)
input bool   STRequireNoEvasion     = true;     // Запрет входов когда ST в режиме «ухода от шума»
input int    STMinBarsForFlip       = 2;        // Игнорировать флип тренда короче N баров (антидребезг)
input bool   UseSTHTF               = true;     // Использовать HTF SuperTrend как доп. фильтр
input ENUM_TIMEFRAMES ST_HTF        = PERIOD_H4;       // Старший ТФ для HTF SuperTrend
input int    STHtfAtrLength         = 10;       // ATR длина HTF
input double STHtfMultiplier        = 3.0;      // Множитель ATR HTF

input group "=== ФИЛЬТР НОВОСТЕЙ (Calendar) ==="
input bool   UseNewsFilter          = true;     // Запрет первых входов перед новостями
input string NewsCurrenciesCSV      = "USD";    // Валюты для фильтра (через запятую)
input int    NewsHighBeforeMin      = 60;       // High-impact: блок за N минут ДО
input int    NewsHighAfterMin       = 30;       // High-impact: блок N минут ПОСЛЕ
input int    NewsMediumBeforeMin    = 20;       // Medium-impact: блок за N минут ДО
input int    NewsMediumAfterMin     = 10;       // Medium-impact: блок N минут ПОСЛЕ
input bool   NewsBlockAveraging     = false;    // Блокировать и усреднения (не только первые входы)

input group "=== СЕТКА ПО ATR ==="
input bool   UseATRGrid        = false;
input ENUM_TIMEFRAMES ATR_TF   = PERIOD_M15;
input int    ATR_Period        = 14;
input double ATR_Multiplier    = 1.0;

input group "=== ДОП. НАСТРОЙКИ СЕТКИ ==="
input ENUM_TIMEFRAMES GridTF   = PERIOD_M5;

input group "=== СТРАТЕГИЯ HILO (Порядок 1) ==="
input bool   ИспользоватьHilo       = true;
input int    MagicHilo              = 852791;
input int    МаксСделокHilo         = 50;
input string КомментарийHilo        = "Алиса1";
input ENUM_APPLIED_PRICE Hilo_SignalType = PRICE_CLOSE;

input group "=== HILO РЕЖИМ (RSI/WPR/СОВМЕСТНО) ==="
input int    Hilo_Mode              = 2;  // 0=RSI, 1=WPR, 2=RSI+WPR

input group "=== HILO RSI НАСТРОЙКИ ==="
input ENUM_TIMEFRAMES Hilo_RSI_TF_Entry   = PERIOD_M1;
input ENUM_TIMEFRAMES Hilo_RSI_TF_Filter  = PERIOD_M30;
input int             Hilo_RSI_Period     = 3;
input double          Hilo_RSI_BuyLevel   = 23.0;
input double          Hilo_RSI_SellLevel  = 75.0;

input group "=== HILO WPR НАСТРОЙКИ ==="
input ENUM_TIMEFRAMES Hilo_WPR_TF_Entry   = PERIOD_M1;
input ENUM_TIMEFRAMES Hilo_WPR_TF_Filter  = PERIOD_M30;
input int             Hilo_WPR_Period     = 3;
input double          Hilo_WPR_BuyLevel   = -80.0;
input double          Hilo_WPR_SellLevel  = -20.0;

input group "=== СТРАТЕГИЯ 15 (Порядок 2) ==="
input bool   Использовать15         = true;
input int    Magic15                = 852792;
input int    МаксСделок15           = 50;
input string Комментарий15          = "Алиса2";
input ENUM_APPLIED_PRICE Strat15_SignalType = PRICE_CLOSE;

input group "=== STRAT 15 РЕЖИМ (RSI/WPR/СОВМЕСТНО) ==="
input int    S15_Mode               = 2;  // 0=RSI, 1=WPR, 2=RSI+WPR

input group "=== STRAT 15 RSI НАСТРОЙКИ ==="
input ENUM_TIMEFRAMES S15_RSI_TF_Entry   = PERIOD_M5;
input ENUM_TIMEFRAMES S15_RSI_TF_Filter  = PERIOD_H1;
input int             S15_RSI_Period     = 6;
input double          S15_RSI_BuyLevel   = 20.0;
input double          S15_RSI_SellLevel  = 80.0;

input group "=== STRAT 15 WPR НАСТРОЙКИ ==="
input ENUM_TIMEFRAMES S15_WPR_TF_Entry   = PERIOD_M5;
input ENUM_TIMEFRAMES S15_WPR_TF_Filter  = PERIOD_H1;
input int             S15_WPR_Period     = 6;
input double          S15_WPR_BuyLevel   = -80.0;
input double          S15_WPR_SellLevel  = -20.0;

input group "=== СТРАТЕГИЯ 16 (Порядок 3) ==="
input bool   Использовать16         = true;
input int    Magic16                = 852793;
input int    МаксСделок16           = 11;
input string Комментарий16          = "Алиса3";
input ENUM_APPLIED_PRICE Strat16_SignalType = PRICE_CLOSE;

input group "=== STRAT 16 РЕЖИМ (RSI/WPR/СОВМЕСТНО) ==="
input int    S16_Mode               = 2;  // 0=RSI, 1=WPR, 2=RSI+WPR

input group "=== STRAT 16 RSI НАСТРОЙКИ ==="
input ENUM_TIMEFRAMES S16_RSI_TF_Entry   = PERIOD_M15;
input ENUM_TIMEFRAMES S16_RSI_TF_Filter  = PERIOD_H4;
input int             S16_RSI_Period     = 9;
input double          S16_RSI_BuyLevel   = 25.0;
input double          S16_RSI_SellLevel  = 80.0;

input group "=== STRAT 16 WPR НАСТРОЙКИ ==="
input ENUM_TIMEFRAMES S16_WPR_TF_Entry   = PERIOD_M15;
input ENUM_TIMEFRAMES S16_WPR_TF_Filter  = PERIOD_H4;
input int             S16_WPR_Period     = 9;
input double          S16_WPR_BuyLevel   = -80.0;
input double          S16_WPR_SellLevel  = -20.0;

input group "=== ЗАЩИТА ОТ РИСКА ==="
input bool   ИспользоватьОстановку  = false;
input double МаксПлавающийУбыток    = 500.0;
input double Проскальзывание        = 5.0;
input double МаксСпредПипсов        = 30.0;     // FIX G/K: макс. допустимый спред в пипсах для входа

// === ГЛОБАЛЬНОЕ ЗАКРЫТИЕ ВСЕХ ОРДЕРОВ ===
input group "=== ГЛОБАЛЬНОЕ ЗАКРЫТИЕ (ВСЕ ОРДЕРА) ==="
input bool   UseGlobalCloseByMoney  = true;      // Закрывать по деньгам
input double GlobalCloseMoney       = 100.0;    // Прибыль в $ для закрытия всех
input bool   UseGlobalCloseByPercent = false;   // Закрывать по процентам
input double GlobalClosePercent     = 2.0;      // Процент прибыли от баланса

// === ЛОКИРОВАНИЕ ПО ПРОСАДКЕ ОТ БАЛАНСА ===
input group "=== ЛОКИРОВАНИЕ ПО ПРОСАДКЕ (ОТ БАЛАНСА) ==="
input bool   UseDrawdownLock        = true;      // Использовать локирование (отключается если UseRecoveryHandoff=true)
input double LockDrawdownPercent    = 5.0;       // Просадка от баланса для лока (%)
input int    LockDurationMinutes    = 30;        // Длительность паузы торговли (мин)
input int    RecoveryCheckMinutes   = 5;         // Проверка через N минут после закрытия лока
input bool   AutoReLockIfNoRecovery = true;      // Открыть новый лок если просадка не снизилась
input bool   CloseLockOnDeinit      = false;     // FIX C: закрывать лок при остановке советника

// === RECOVERY HANDOFF ===
input group "=== RECOVERY HANDOFF (Передача корзины Recovery EA) ==="
input bool   UseRecoveryHandoff     = false;     // Передавать DD-корзину советнику RecoveryEA
input double HandoffMinDD           = 5.0;       // Триггер передачи: DD от баланса (%)
input double HandoffResumeDD        = 2.0;       // Возобновлять торговлю когда DD < этого значения (%)
input string HandoffMagicsCSV       = "852791,852792,852793"; // Магики Алисы (для Recovery EA)

input group "=== НАСТРОЙКИ GUI ==="
input bool   ПоказыватьGUI          = true;
input int    GUI_X                  = 20;
input int    GUI_Y                  = 30;
input int    GUI_StepY              = 50;
input color  GUI_ColorMain          = clrLime;
input color  GUI_ColorHilo          = clrDeepSkyBlue;
input color  GUI_Color15            = clrYellow;
input color  GUI_Color16            = clrMagenta;
input color  GUI_ColorGlobal        = clrOrange;
input color  GUI_ColorLock          = clrRed;
input int    GUI_FontSize           = 10;
input bool   Panel_RightCorner      = false;
input color  Panel_BackColor        = clrBlack;
input int    Panel_Padding          = 10;
input int    Panel_HeaderMargin     = 3;

input group "=== ДОПОЛНИТЕЛЬНЫЕ ФУНКЦИИ ==="
input bool   ЧастичноеЗакрытие      = false;
input double ПартиалПроцентTP       = 50.0;     // FIX A: единый % от ТейкПрофит для партиала (BUY и SELL)
input bool   UseBreakeven           = false;
input double BreakevenBuffer        = 5.0;
input bool   EnableDetailedLog      = false;

int g_ma_fast_handle  = INVALID_HANDLE;
int g_ma_mid_handle   = INVALID_HANDLE;
int g_ma_slow_handle  = INVALID_HANDLE;
int g_atr_handle      = INVALID_HANDLE;

// === SuperTrend filter state ===
int g_st_ltf_handle   = INVALID_HANDLE;   // iCustom handle для LTF SuperTrend
int g_st_htf_handle   = INVALID_HANDLE;   // iCustom handle для HTF SuperTrend
int g_st_ltf_trend    = 0;                 // текущий LTF тренд: +1/-1
int g_st_htf_trend    = 0;                 // текущий HTF тренд: +1/-1
int g_st_flip_bars    = 0;                 // баров прошло с последнего флипа LTF
int g_st_prev_trend   = 0;                 // предыдущий LTF тренд (для счёта flip_bars)
bool g_st_evasive     = false;             // LTF ST в режиме evasion

// === News filter state ===
bool     g_news_block_entry     = false;   // блокировка первого входа
bool     g_news_block_averaging = false;   // блокировка усреднения (если NewsBlockAveraging)
string   g_news_block_reason    = "";      // название события, вызвавшего блок
datetime g_news_last_check      = 0;       // когда последний раз опрашивали календарь

datetime g_last_grid_bar_time = 0;

bool g_trend_buy_allowed  = false;
bool g_trend_sell_allowed = false;

// FIX E: sentinel — на первом тике состояние «ещё не считали», тренд-закрытия не активируются
const int TREND_STATE_UNINIT = -2;
int g_last_trend_state = TREND_STATE_UNINIT;

// === ПЕРЕМЕННЫЕ ДЛЯ ЛОКИРОВАНИЯ ПО ПРОСАДКЕ ===
bool       g_lock_active = false;
datetime   g_lock_start_time = 0;
datetime   g_lock_end_time = 0;
double     g_lock_start_balance = 0;
double     g_lock_max_drawdown = 0;
int        g_total_locks = 0;
bool       g_waiting_recovery_check = false;
datetime   g_recovery_check_time = 0;

// === HANDOFF: имена GV и стейт ===
const string GV_HANDOFF_HALT     = "Alisa.Halt";
const string GV_HANDOFF_EQUITY   = "Alisa.AttachEquity";
const string GV_HANDOFF_ACTIVE   = "Alisa.Recovery.Active";
bool g_handoff_halted = false;

//+------------------------------------------------------------------+
//| FIX K: размер «пункта трейдера» с авто-коррекцией для 3/5-знаков |
//+------------------------------------------------------------------+
double PipSize()
{
   int    d  = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   double pt = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   return (d == 3 || d == 5) ? pt * 10.0 : pt;
}

//+------------------------------------------------------------------+
//| FIX I: проверка принадлежности позиции стратегиям Алисы          |
//+------------------------------------------------------------------+
bool IsAlisaStrategyMagic(const ulong m)
{
   return (m == (ulong)MagicHilo || m == (ulong)Magic15 || m == (ulong)Magic16);
}

//+------------------------------------------------------------------+
//| FIX B: единая параметризованная функция закрытия                 |
//|   dir: +1 BUY, -1 SELL, 0 ALL                                    |
//|   includeLock: закрывать ли позиции с magic=999999 (LOCK#)       |
//+------------------------------------------------------------------+
void CloseManagedPositions(int dir, bool includeLock)
{
   CTrade trade;
   trade.SetTypeFillingBySymbol(Symbol());
   trade.SetDeviationInPoints((ulong)Проскальзывание);

   CPositionInfo pos;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(!pos.SelectByTicket(tk))    continue;
      if(pos.Symbol() != Symbol())   continue;

      ulong m       = pos.Magic();
      bool  isStrat = IsAlisaStrategyMagic(m);
      bool  isLock  = (m == 999999);
      if(!isStrat && !(includeLock && isLock)) continue;

      if(dir > 0 && pos.PositionType() != POSITION_TYPE_BUY)  continue;
      if(dir < 0 && pos.PositionType() != POSITION_TYPE_SELL) continue;

      trade.PositionClose(tk);
   }

   // FIX B: закрытие лока через эту функцию синхронизирует стейт
   if(includeLock && (dir == 0))
   {
      g_lock_active = false;
      g_waiting_recovery_check = false;
   }
}

void CloseBuyPositions()         { CloseManagedPositions(+1, true); }
void CloseSellPositions()        { CloseManagedPositions(-1, true); }
void CloseAllStrategyPositions() { CloseManagedPositions( 0, true); }

//+------------------------------------------------------------------+
//| Просадка от баланса в процентах                                  |
//+------------------------------------------------------------------+
double GetCurrentDrawdownPercent()
{
   double balance = acc.Balance();
   double equity  = acc.Equity();
   if(balance <= 0) return 0;
   double drawdown = balance - equity;
   if(drawdown <= 0) return 0;
   return (drawdown / balance) * 100.0;
}

//+------------------------------------------------------------------+
//| HANDOFF: установить/снять флаги                                  |
//+------------------------------------------------------------------+
void HandoffSetHalt(bool halted)
{
   if(halted)
   {
      GlobalVariableSet(GV_HANDOFF_HALT, 1.0);
      GlobalVariableSet(GV_HANDOFF_EQUITY, AccountInfoDouble(ACCOUNT_EQUITY));
      GlobalVariableTemp(GV_HANDOFF_HALT);   // не сохранять в файл, чисто межпроцессно
      GlobalVariableTemp(GV_HANDOFF_EQUITY);
      Print("HANDOFF: halt=1, equity=", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2),
            ". Recovery EA must be attached on this symbol with matching magics: ",
            HandoffMagicsCSV);
   }
   else
   {
      if(GlobalVariableCheck(GV_HANDOFF_HALT))   GlobalVariableDel(GV_HANDOFF_HALT);
      if(GlobalVariableCheck(GV_HANDOFF_EQUITY)) GlobalVariableDel(GV_HANDOFF_EQUITY);
      Print("HANDOFF: halt=0. Trading resumed.");
   }
   g_handoff_halted = halted;
}

bool HandoffRecoveryActive()
{
   if(!GlobalVariableCheck(GV_HANDOFF_ACTIVE)) return false;
   return GlobalVariableGet(GV_HANDOFF_ACTIVE) > 0.5;
}

//+------------------------------------------------------------------+
//| Управление DD-механикой: handoff имеет приоритет над локом       |
//+------------------------------------------------------------------+
void CheckAndManageDrawdownLock()
{
   double dd_now = GetCurrentDrawdownPercent();

   //--- HANDOFF-режим: лок не используется
   if(UseRecoveryHandoff)
   {
      if(!g_handoff_halted)
      {
         if(dd_now >= HandoffMinDD)
         {
            HandoffSetHalt(true);
            Print("HANDOFF triggered. DD=", DoubleToString(dd_now, 2), "%");
         }
         return;
      }

      // halted: возобновляемся когда Recovery отчитался И просадка ушла
      bool recoveryDone = !HandoffRecoveryActive();
      if(recoveryDone && dd_now < HandoffResumeDD)
      {
         HandoffSetHalt(false);
         Print("HANDOFF cleared. DD=", DoubleToString(dd_now, 2), "%");
      }
      return;
   }

   //--- классический лок (legacy)
   if(!UseDrawdownLock) return;
   datetime now = TimeCurrent();

   if(!g_lock_active && !g_waiting_recovery_check)
   {
      if(dd_now >= LockDrawdownPercent)
         ActivateLock();
      return;
   }

   if(g_lock_active)
   {
      if(dd_now > g_lock_max_drawdown) g_lock_max_drawdown = dd_now;

      if(now >= g_lock_end_time)
      {
         CloseLockPosition();
         g_lock_active = false;
         g_waiting_recovery_check = true;
         g_recovery_check_time = now + RecoveryCheckMinutes * 60;
         Print("Время лока истекло (", LockDurationMinutes, " мин). Лок закрыт. ",
               "Проверка восстановления через ", RecoveryCheckMinutes, " мин.");
      }
      return;
   }

   if(g_waiting_recovery_check && now >= g_recovery_check_time)
   {
      g_waiting_recovery_check = false;
      double dd2 = GetCurrentDrawdownPercent();
      if(AutoReLockIfNoRecovery && dd2 >= LockDrawdownPercent * 0.8)
      {
         Print("Просадка не восстановилась: ", DoubleToString(dd2, 2), "% — новый лок.");
         ActivateLock();
      }
      else
         Print("Просадка восстановилась: ", DoubleToString(dd2, 2), "%. Торговля продолжается.");
   }
}

void ActivateLock()
{
   datetime now = TimeCurrent();
   g_lock_active        = true;
   g_lock_start_time    = now;
   g_lock_end_time      = now + LockDurationMinutes * 60;
   g_lock_start_balance = acc.Balance();
   g_lock_max_drawdown  = GetCurrentDrawdownPercent();
   g_total_locks++;
   Print("ЛОК АКТИВИРОВАН #", g_total_locks, ". Просадка: ",
         DoubleToString(g_lock_max_drawdown, 2), "%, остановка торговли на ",
         LockDurationMinutes, " мин.");
   OpenLockPosition();
}

//+------------------------------------------------------------------+
//| Открытие локирующей позиции (встречная нетто)                    |
//+------------------------------------------------------------------+
void OpenLockPosition()
{
   double net_position = 0;
   CPositionInfo pos;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!pos.SelectByTicket(ticket)) continue;
      if(pos.Symbol() != Symbol())    continue;
      if(!IsAlisaStrategyMagic(pos.Magic())) continue;

      if(pos.PositionType() == POSITION_TYPE_BUY)
         net_position += pos.Volume();
      else
         net_position -= pos.Volume();
   }

   if(net_position == 0)
   {
      Print("Нет открытых позиций для локирования");
      return;
   }

   ENUM_ORDER_TYPE lock_type = (net_position > 0) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   double lock_volume = MathAbs(net_position);

   double min_lot  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   double step_lot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
   if(step_lot <= 0) step_lot = 0.01;

   lock_volume = MathFloor(lock_volume / step_lot) * step_lot;
   if(lock_volume < min_lot) lock_volume = min_lot;
   if(lock_volume > max_lot) lock_volume = max_lot;

   string comment = "LOCK#" + IntegerToString(g_total_locks);

   CTrade trade;
   trade.SetExpertMagicNumber(999999);
   trade.SetTypeFillingBySymbol(Symbol());
   trade.SetDeviationInPoints((ulong)Проскальзывание);

   bool ok = (lock_type == ORDER_TYPE_SELL)
             ? trade.Sell(lock_volume, Symbol(), 0, 0, 0, comment)
             : trade.Buy (lock_volume, Symbol(), 0, 0, 0, comment);

   if(ok && trade.ResultRetcode() == TRADE_RETCODE_DONE)
      Print("Лок-ордер открыт: #", trade.ResultOrder(), " Объём=", lock_volume,
            " Тип=", (lock_type == ORDER_TYPE_BUY ? "BUY" : "SELL"));
   else
      Print("Ошибка открытия лока: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
}

void CloseLockPosition()
{
   CTrade trade;
   trade.SetTypeFillingBySymbol(Symbol());
   CPositionInfo pos;

   int closed_count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!pos.SelectByTicket(ticket)) continue;
      if(pos.Symbol() != Symbol())    continue;
      if(pos.Magic() != 999999)       continue;
      if(StringFind(pos.Comment(), "LOCK#") < 0) continue;

      if(trade.PositionClose(ticket) && trade.ResultRetcode() == TRADE_RETCODE_DONE)
         closed_count++;
   }
   if(closed_count > 0) Print("Закрыто лок-ордеров: ", closed_count);
}

//+------------------------------------------------------------------+
//| Разрешение торговли — учитывает и handoff, и лок                 |
//+------------------------------------------------------------------+
bool IsTradingAllowed()
{
   if(UseRecoveryHandoff && g_handoff_halted) return false;
   if(UseDrawdownLock && g_lock_active)       return false;
   return true;
}

//+------------------------------------------------------------------+
//| Статус для GUI                                                   |
//+------------------------------------------------------------------+
string GetLockStatus()
{
   if(UseRecoveryHandoff)
   {
      double dd = GetCurrentDrawdownPercent();
      if(g_handoff_halted)
      {
         string ra = HandoffRecoveryActive() ? "Recovery: ACT" : "Recovery: idle";
         return "HANDOFF | DD=" + DoubleToString(dd, 2) + "% | " + ra;
      }
      return "Handoff: armed | DD=" + DoubleToString(dd, 2) + "%";
   }

   if(!UseDrawdownLock) return "Лок: OFF";

   if(g_lock_active)
   {
      int remaining = (int)(g_lock_end_time - TimeCurrent()) / 60;
      if(remaining < 0) remaining = 0;
      return "ЛОК #" + IntegerToString(g_total_locks) +
             " | Осталось: " + IntegerToString(remaining) + "мин | DD=" +
             DoubleToString(GetCurrentDrawdownPercent(), 2) + "%";
   }
   if(g_waiting_recovery_check)
   {
      int wait_min = (int)(g_recovery_check_time - TimeCurrent()) / 60;
      if(wait_min < 0) wait_min = 0;
      return "Проверка: " + IntegerToString(wait_min) + "мин | DD=" +
             DoubleToString(GetCurrentDrawdownPercent(), 2) + "%";
   }
   return "Лок: Готов | DD=" + DoubleToString(GetCurrentDrawdownPercent(), 2) + "%";
}

//+------------------------------------------------------------------+
//| Тренд-флаги и закрытия по смене тренда                           |
//+------------------------------------------------------------------+
void UpdateTrendFlags()
{
   g_trend_buy_allowed  = false;
   g_trend_sell_allowed = false;
   int current_trend = 0;

   if(UseSTFilter)
   {
      //--- Читаем LTF SuperTrend buffer #14 (BufTrend), shift=1 (закрытый бар)
      double st_trend_buf[1];
      double st_evasive_buf[1];
      g_st_ltf_trend = 0;
      g_st_evasive   = false;

      if(g_st_ltf_handle != INVALID_HANDLE &&
         CopyBuffer(g_st_ltf_handle, 14, 1, 1, st_trend_buf) > 0)
      {
         g_st_ltf_trend = (st_trend_buf[0] > 0.5) ? 1 : -1;
      }
      // buffer #17 = BufEvasive (1.0 если evasive)
      if(STRequireNoEvasion && g_st_ltf_handle != INVALID_HANDLE &&
         CopyBuffer(g_st_ltf_handle, 17, 1, 1, st_evasive_buf) > 0)
      {
         g_st_evasive = (st_evasive_buf[0] > 0.5);
      }

      //--- HTF SuperTrend
      g_st_htf_trend = 0;
      if(UseSTHTF && g_st_htf_handle != INVALID_HANDLE)
      {
         double htf_buf[1];
         if(CopyBuffer(g_st_htf_handle, 14, 1, 1, htf_buf) > 0)
            g_st_htf_trend = (htf_buf[0] > 0.5) ? 1 : -1;
      }

      //--- Счётчик баров с последнего флипа (антидребезг)
      if(g_st_ltf_trend != 0 && g_st_ltf_trend != g_st_prev_trend)
      {
         g_st_flip_bars = 0;  // только что флипнул
         g_st_prev_trend = g_st_ltf_trend;
      }
      else
         g_st_flip_bars++;

      //--- Определяем финальный тренд: LTF + HTF agreement
      bool ltf_bull = (g_st_ltf_trend == 1);
      bool ltf_bear = (g_st_ltf_trend == -1);
      bool htf_ok_buy  = (!UseSTHTF || g_st_htf_trend >= 0);  // HTF не мешает (бычий или нет данных)
      bool htf_ok_sell = (!UseSTHTF || g_st_htf_trend <= 0);  // HTF не мешает (медвежий или нет данных)

      // Evasion-блок: если ST в зоне шума — не торгуем
      bool evasion_block = (STRequireNoEvasion && g_st_evasive);

      // Антидребезг: если флип произошёл меньше STMinBarsForFlip баров назад — держим предыдущее направление
      bool flip_cooldown = (STMinBarsForFlip > 0 && g_st_flip_bars < STMinBarsForFlip);

      if(!evasion_block && !flip_cooldown)
      {
         if(ltf_bull && htf_ok_buy)
         { g_trend_buy_allowed = true; g_trend_sell_allowed = false; current_trend = 1; }
         else if(ltf_bear && htf_ok_sell)
         { g_trend_buy_allowed = false; g_trend_sell_allowed = true; current_trend = -1; }
         else
         { g_trend_buy_allowed = false; g_trend_sell_allowed = false; current_trend = 0; }
      }
      // При evasion/cooldown оба флага остаются false → торговля заблокирована
   }
   else if(UseТрендФильтр)
   {
      //--- LEGACY: 3-MA фильтр
      double fast = GetMA(g_ma_fast_handle);
      double mid  = GetMA(g_ma_mid_handle);
      double slow = GetMA(g_ma_slow_handle);

      if(fast > mid && mid > slow)
      { g_trend_buy_allowed = true;  g_trend_sell_allowed = false; current_trend =  1; }
      else if(fast < mid && mid < slow)
      { g_trend_buy_allowed = false; g_trend_sell_allowed = true;  current_trend = -1; }
      else
      { g_trend_buy_allowed = false; g_trend_sell_allowed = false; current_trend =  0; }

      if(ForbidAlisaTradingInFlat && current_trend == 0)
      { g_trend_buy_allowed = false; g_trend_sell_allowed = false; }
   }
   else
   {
      // Нет фильтра — всё разрешено
      g_trend_buy_allowed = g_trend_sell_allowed = true;
      current_trend = 1;
   }

   // FIX E: на uninit-состоянии тренд-закрытий не делаем
   if(CloseOnTrendChange &&
      g_last_trend_state != TREND_STATE_UNINIT &&
      g_last_trend_state != 0 &&
      current_trend != g_last_trend_state)
   {
      if(g_last_trend_state == 1 && current_trend == -1 && CloseBuyOnBearTrend)
      { CloseBuyPositions();  Print("[TREND] BULL->BEAR: закрыты BUY"); }
      if(g_last_trend_state == -1 && current_trend == 1 && CloseSellOnBullTrend)
      { CloseSellPositions(); Print("[TREND] BEAR->BULL: закрыты SELL"); }
      if(current_trend == 0 && CloseOnFlat)
      { CloseAllStrategyPositions(); Print("[TREND] FLAT: закрыто всё"); }
   }
   // выход из FLAT в направление — тоже только после первого валидного измерения
   if(CloseOnTrendChange &&
      g_last_trend_state == 0 && current_trend != 0)
   {
      if(current_trend == 1 && CloseSellOnBullTrend)
      { CloseSellPositions(); Print("[TREND] FLAT->BULL: закрыты SELL"); }
      else if(current_trend == -1 && CloseBuyOnBearTrend)
      { CloseBuyPositions();  Print("[TREND] FLAT->BEAR: закрыты BUY"); }
   }

   g_last_trend_state = current_trend;
}

//+------------------------------------------------------------------+
//| Фильтр новостей — опрос встроенного календаря MT5                |
//|   Блокирует первые входы (и опционально усреднения) в окнах      |
//|   вокруг USD high/medium impact событий.                         |
//+------------------------------------------------------------------+
void UpdateNewsFilter()
{
   g_news_block_entry     = false;
   g_news_block_averaging = false;
   g_news_block_reason    = "";

   if(!UseNewsFilter) return;

   // Опрашиваем календарь не чаще 1 раза в 30 секунд (экономия ресурсов)
   datetime now = TimeCurrent();
   if(now - g_news_last_check < 30 && g_news_last_check > 0)
   {
      // Используем кэшированное состояние — ничего не пересчитываем.
      // Флаги уже были установлены на прошлом вызове — восстановим из «статического кэша».
      // Кэш реализуем через static:
   }
   g_news_last_check = now;

   // Окна поиска: от (now - maxBefore) до (now + maxAfter)
   int maxBefore = MathMax(NewsHighBeforeMin, NewsMediumBeforeMin) * 60;
   int maxAfter  = MathMax(NewsHighAfterMin,  NewsMediumAfterMin)  * 60;
   datetime from = now - maxBefore;
   datetime to   = now + maxAfter;

   // Парсим валюты из CSV
   string currencies[];
   int numCurr = StringSplit(NewsCurrenciesCSV, ',', currencies);

   // Перебираем события через CalendarValueHistory
   MqlCalendarValue values[];
   int total = CalendarValueHistory(values, from, to);
   if(total <= 0) return;

   for(int i = 0; i < total; i++)
   {
      // Получаем описание события
      MqlCalendarEvent evt;
      if(!CalendarEventById(values[i].event_id, evt)) continue;

      // Получаем страну
      MqlCalendarCountry country;
      if(!CalendarCountryById(evt.country_id, country)) continue;

      // Проверяем валюту
      bool currencyMatch = false;
      for(int c = 0; c < numCurr; c++)
      {
         string cur = currencies[c];
         StringTrimLeft(cur); StringTrimRight(cur);
         if(StringCompare(country.currency, cur, false) == 0)
         { currencyMatch = true; break; }
      }
      if(!currencyMatch) continue;

      // Определяем importance
      int beforeSec = 0, afterSec = 0;
      if(evt.importance == CALENDAR_IMPORTANCE_HIGH)
      { beforeSec = NewsHighBeforeMin * 60;  afterSec = NewsHighAfterMin * 60; }
      else if(evt.importance == CALENDAR_IMPORTANCE_MODERATE)
      { beforeSec = NewsMediumBeforeMin * 60; afterSec = NewsMediumAfterMin * 60; }
      else
         continue;  // Low-impact — пропускаем

      // Проверяем попадание текущего времени в окно
      datetime eventTime = values[i].time;
      if(now >= eventTime - beforeSec && now <= eventTime + afterSec)
      {
         g_news_block_entry = true;
         if(NewsBlockAveraging) g_news_block_averaging = true;
         g_news_block_reason = evt.name;
         // Достаточно первого попадания — один блок перекрывает всё
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Класс стратегии (RSI/WPR/RSI+WPR)                                |
//+------------------------------------------------------------------+
class CGridStrategy
{
private:
   int            m_magic;
   int            m_max_trades;
   bool           m_enabled;
   string         m_baseComment;
   int            m_mode;

   int            m_rsi_entry_handle;
   int            m_rsi_filter_handle;
   int            m_rsi_period;
   double         m_rsi_buyLevel;
   double         m_rsi_sellLevel;

   int            m_wpr_entry_handle;
   int            m_wpr_filter_handle;
   int            m_wpr_period;
   double         m_wpr_buyLevel;
   double         m_wpr_sellLevel;

   CTrade         m_trade;
   CPositionInfo  m_pos;

   bool           m_buy_signal_sent;
   bool           m_sell_signal_sent;

   datetime       m_last_buy_time;
   datetime       m_last_sell_time;
   double         m_last_buy_price;
   double         m_last_sell_price;
   double         m_last_buy_lot;
   double         m_last_sell_lot;

   void ReleaseAllHandles()
   {
      if(m_rsi_entry_handle  != INVALID_HANDLE) { IndicatorRelease(m_rsi_entry_handle);  m_rsi_entry_handle  = INVALID_HANDLE; }
      if(m_rsi_filter_handle != INVALID_HANDLE) { IndicatorRelease(m_rsi_filter_handle); m_rsi_filter_handle = INVALID_HANDLE; }
      if(m_wpr_entry_handle  != INVALID_HANDLE) { IndicatorRelease(m_wpr_entry_handle);  m_wpr_entry_handle  = INVALID_HANDLE; }
      if(m_wpr_filter_handle != INVALID_HANDLE) { IndicatorRelease(m_wpr_filter_handle); m_wpr_filter_handle = INVALID_HANDLE; }
   }

public:
   int            m_cntBuy;
   int            m_cntSell;
   double         m_totalLotBuy;
   double         m_totalLotSell;
   double         m_floatingProfit;

   CGridStrategy()
   {
      m_rsi_entry_handle = m_rsi_filter_handle =
         m_wpr_entry_handle = m_wpr_filter_handle = INVALID_HANDLE;
   }

   ~CGridStrategy() { ReleaseAllHandles(); }

   void Init(int magic, int max_trades, bool enable,
             ENUM_TIMEFRAMES tf_rsi_entry, ENUM_TIMEFRAMES tf_rsi_filter,
             int rsi_period, double rsi_buyLevel, double rsi_sellLevel,
             ENUM_TIMEFRAMES tf_wpr_entry, ENUM_TIMEFRAMES tf_wpr_filter,
             int wpr_period, double wpr_buyLevel, double wpr_sellLevel,
             ENUM_APPLIED_PRICE signal_type_param,   // FIX M: больше не используется, оставлено для совместимости сигнатуры
             string baseComment,
             int mode = 2)
   {
      m_magic         = magic;
      m_max_trades    = max_trades;
      m_enabled       = enable;
      m_baseComment   = baseComment;
      m_mode          = mode;

      m_rsi_period    = rsi_period;
      m_rsi_buyLevel  = rsi_buyLevel;
      m_rsi_sellLevel = rsi_sellLevel;

      m_wpr_period    = wpr_period;
      m_wpr_buyLevel  = wpr_buyLevel;
      m_wpr_sellLevel = wpr_sellLevel;

      m_trade.SetExpertMagicNumber(m_magic);
      m_trade.SetDeviationInPoints((ulong)Проскальзывание);
      m_trade.SetTypeFillingBySymbol(Symbol());
      m_trade.SetAsyncMode(false);

      // FIX H: при ошибке любого хендла — освобождаем все ранее созданные
      m_rsi_entry_handle  = iRSI(Symbol(), tf_rsi_entry,  m_rsi_period, PRICE_CLOSE);
      if(m_rsi_entry_handle  == INVALID_HANDLE) { Print("[", m_baseComment, "] RSI entry handle failed");  ReleaseAllHandles(); m_enabled = false; return; }

      m_rsi_filter_handle = iRSI(Symbol(), tf_rsi_filter, m_rsi_period, PRICE_CLOSE);
      if(m_rsi_filter_handle == INVALID_HANDLE) { Print("[", m_baseComment, "] RSI filter handle failed"); ReleaseAllHandles(); m_enabled = false; return; }

      m_wpr_entry_handle  = iWPR(Symbol(), tf_wpr_entry,  m_wpr_period);
      if(m_wpr_entry_handle  == INVALID_HANDLE) { Print("[", m_baseComment, "] WPR entry handle failed");  ReleaseAllHandles(); m_enabled = false; return; }

      m_wpr_filter_handle = iWPR(Symbol(), tf_wpr_filter, m_wpr_period);
      if(m_wpr_filter_handle == INVALID_HANDLE) { Print("[", m_baseComment, "] WPR filter handle failed"); ReleaseAllHandles(); m_enabled = false; return; }

      m_buy_signal_sent  = false;
      m_sell_signal_sent = false;
      m_last_buy_time    = m_last_sell_time = 0;
   }

   void OnTickProcess(bool is_new_grid_bar)
   {
      if(!m_enabled) return;
      if(!IsTradingAllowed()) return;

      m_cntBuy = m_cntSell = 0;
      m_totalLotBuy = m_totalLotSell = 0.0;
      m_floatingProfit = 0.0;
      m_last_buy_time = m_last_sell_time = 0;
      m_last_buy_price = m_last_sell_price = 0;
      m_last_buy_lot = m_last_sell_lot = 0;

      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(!m_pos.SelectByIndex(i)) continue;
         if(m_pos.Symbol() != Symbol() || m_pos.Magic() != (ulong)m_magic) continue;

         if(m_pos.PositionType() == POSITION_TYPE_BUY)
         {
            m_cntBuy++;
            m_totalLotBuy    += m_pos.Volume();
            m_floatingProfit += m_pos.Profit();
            if(m_pos.Time() > m_last_buy_time)
            {
               m_last_buy_time  = m_pos.Time();
               m_last_buy_price = m_pos.PriceOpen();
               m_last_buy_lot   = m_pos.Volume();
            }
         }
         else if(m_pos.PositionType() == POSITION_TYPE_SELL)
         {
            m_cntSell++;
            m_totalLotSell   += m_pos.Volume();
            m_floatingProfit += m_pos.Profit();
            if(m_pos.Time() > m_last_sell_time)
            {
               m_last_sell_time  = m_pos.Time();
               m_last_sell_price = m_pos.PriceOpen();
               m_last_sell_lot   = m_pos.Volume();
            }
         }
      }

      double rsi_entry  = GetRSI(m_rsi_entry_handle, 1);
      double rsi_filter = GetRSI(m_rsi_filter_handle, 1);
      double wpr_entry  = GetWPR(m_wpr_entry_handle, 1);
      double wpr_filter = GetWPR(m_wpr_filter_handle, 1);

      bool rsi_buy_signal  = (rsi_entry < m_rsi_buyLevel  && rsi_filter < 70.0);
      bool rsi_sell_signal = (rsi_entry > m_rsi_sellLevel && rsi_filter > 30.0);
      bool wpr_buy_signal  = (wpr_entry < m_wpr_buyLevel  && wpr_filter < -80.0);
      bool wpr_sell_signal = (wpr_entry > m_wpr_sellLevel && wpr_filter > -20.0);

      bool buy_signal = false, sell_signal = false;
      if     (m_mode == 0) { buy_signal = rsi_buy_signal;                 sell_signal = rsi_sell_signal; }
      else if(m_mode == 1) { buy_signal = wpr_buy_signal;                 sell_signal = wpr_sell_signal; }
      else                 { buy_signal = (rsi_buy_signal && wpr_buy_signal);
                             sell_signal = (rsi_sell_signal && wpr_sell_signal); }

      if(РазрешитьBuy && m_cntBuy < m_max_trades && buy_signal && g_trend_buy_allowed)
      {
         // News filter: block first entry or averaging
         bool news_blocks_this = false;
         if(m_cntBuy == 0 && g_news_block_entry) news_blocks_this = true;
         if(m_cntBuy > 0  && g_news_block_averaging) news_blocks_this = true;

         if(!news_blocks_this)
         {
            if(m_cntBuy == 0 && !m_buy_signal_sent)
            {
               OpenOrder(ORDER_TYPE_BUY, GetStartLot(), m_baseComment + " BUY start");
               m_buy_signal_sent = true;
            }
            else if(m_cntBuy > 0 && is_new_grid_bar)
            {
               double step = GetGridStepPoints() * symb.Point();
               if(m_last_buy_price > 0 && m_last_buy_price - symb.Ask() >= step)
                  OpenOrder(ORDER_TYPE_BUY, CalculateNextLot(m_last_buy_lot), m_baseComment + " BUY grid");
            }
         }
      }
      else if(!buy_signal)
         m_buy_signal_sent = false;

      if(РазрешитьSell && m_cntSell < m_max_trades && sell_signal && g_trend_sell_allowed)
      {
         // News filter: block first entry or averaging
         bool news_blocks_this = false;
         if(m_cntSell == 0 && g_news_block_entry) news_blocks_this = true;
         if(m_cntSell > 0  && g_news_block_averaging) news_blocks_this = true;

         if(!news_blocks_this)
         {
            if(m_cntSell == 0 && !m_sell_signal_sent)
            {
               OpenOrder(ORDER_TYPE_SELL, GetStartLot(), m_baseComment + " SELL start");
               m_sell_signal_sent = true;
            }
            else if(m_cntSell > 0 && is_new_grid_bar)
            {
               double step = GetGridStepPoints() * symb.Point();
               if(m_last_sell_price > 0 && symb.Bid() - m_last_sell_price >= step)
                  OpenOrder(ORDER_TYPE_SELL, CalculateNextLot(m_last_sell_lot), m_baseComment + " SELL grid");
            }
         }
      }
      else if(!sell_signal)
         m_sell_signal_sent = false;

      ManageTakeProfitOptimized(m_cntBuy, m_cntSell);
      if(ЧастичноеЗакрытие) ManagePartialCloses(m_cntBuy, m_cntSell);
      if(UseBreakeven)      ManageBreakeven(m_cntBuy, m_cntSell);
   }

private:
   double GetStartLot()
   {
      if(НачальныйЛот > 0) return NormalizeVolume(НачальныйЛот);

      double riskAmount = acc.Balance() * (РискПроцентов / 100.0);
      double tickValue  = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
      if(tickValue <= 0) tickValue = 1.0;
      double pipValue = tickValue * symb.Point();
      if(pipValue <= 0) pipValue = 0.0001;
      double maxRiskOnTrade = ШагСетки * pipValue;
      if(maxRiskOnTrade <= 0) maxRiskOnTrade = 0.001;
      double calculatedLot = riskAmount / maxRiskOnTrade;
      if(calculatedLot > МаксЛот) calculatedLot = МаксЛот;
      return NormalizeVolume(calculatedLot);
   }

   double GetRSI(int handle, int shift)
   {
      if(handle == INVALID_HANDLE) return 50.0;
      double buf[1];
      return (CopyBuffer(handle, 0, shift, 1, buf) > 0) ? buf[0] : 50.0;
   }

   double GetWPR(int handle, int shift)
   {
      if(handle == INVALID_HANDLE) return -50.0;
      double buf[1];
      return (CopyBuffer(handle, 0, shift, 1, buf) > 0) ? buf[0] : -50.0;
   }

   double CalculateNextLot(double lastLot)
   {
      double stepVol = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
      if(stepVol <= 0.0) stepVol = 0.01;
      double nextLot = lastLot * МножительЛота;
      nextLot = MathFloor(nextLot / stepVol) * stepVol;
      if(МножительЛота > 1.0 && nextLot <= lastLot)
      {
         nextLot = lastLot + stepVol;
         nextLot = MathFloor(nextLot / stepVol) * stepVol;
      }
      if(nextLot > МаксЛот) nextLot = МаксЛот;
      return NormalizeVolume(nextLot);
   }

   double NormalizeVolume(double volume)
   {
      double stepVol = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
      if(stepVol <= 0.0) stepVol = 0.01;
      int dvol = (int)MathRound(-MathLog10(stepVol));
      if(dvol < 1) dvol = 1;
      if(dvol > 4) dvol = 4;
      volume = MathFloor(volume / stepVol) * stepVol;
      return NormalizeDouble(volume, dvol);
   }

   void OpenOrder(ENUM_ORDER_TYPE type, double volume, string comment)
   {
      if(volume <= 0) return;
      if(volume > МаксЛот) volume = МаксЛот;
      volume = NormalizeVolume(volume);

      double minMargin = SymbolInfoDouble(Symbol(), SYMBOL_MARGIN_INITIAL);
      double required  = minMargin * volume * 1.1;
      if(acc.FreeMargin() < required)
      {
         if(EnableDetailedLog) PrintFormat("[%s] Skip: free margin %.2f < required %.2f",
                                           m_baseComment, acc.FreeMargin(), required);
         return;
      }

      // FIX G/K: спред в пипсах через свежие котировки
      symb.RefreshRates();
      double curSpread = symb.Ask() - symb.Bid();
      double maxAllowed = МаксСпредПипсов * PipSize();
      if(curSpread > maxAllowed)
      {
         if(EnableDetailedLog) PrintFormat("[%s] Skip: spread %.1f pips > max %.1f",
                                           m_baseComment, curSpread / PipSize(), МаксСпредПипсов);
         return;
      }

      double price = (type == ORDER_TYPE_BUY) ? symb.Ask() : symb.Bid();

      bool ok = (type == ORDER_TYPE_BUY)
                ? m_trade.Buy (volume, Symbol(), price, 0, 0, comment)
                : m_trade.Sell(volume, Symbol(), price, 0, 0, comment);

      // FIX J: лог результата
      if(!ok || m_trade.ResultRetcode() != TRADE_RETCODE_DONE)
         PrintFormat("[%s] OpenOrder %s %.2f @%.5f failed: ret=%d %s",
                     m_baseComment, (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
                     volume, price, m_trade.ResultRetcode(),
                     m_trade.ResultRetcodeDescription());
   }

   void ManageTakeProfitOptimized(int buys, int sells)
   {
      if(buys == 0 && sells == 0) return;

      double totalLotBuy = 0, totalLotSell = 0;
      double avgBuyPrice = 0, avgSellPrice = 0;

      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(!m_pos.SelectByIndex(i)) continue;
         if(m_pos.Symbol() != Symbol() || m_pos.Magic() != (ulong)m_magic) continue;
         if(m_pos.PositionType() == POSITION_TYPE_BUY)
         { avgBuyPrice  += m_pos.PriceOpen() * m_pos.Volume(); totalLotBuy  += m_pos.Volume(); }
         else if(m_pos.PositionType() == POSITION_TYPE_SELL)
         { avgSellPrice += m_pos.PriceOpen() * m_pos.Volume(); totalLotSell += m_pos.Volume(); }
      }

      if(totalLotBuy > 0)
      {
         avgBuyPrice /= totalLotBuy;
         double tpPrice = avgBuyPrice + ТейкПрофит * symb.Point();
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            if(!m_pos.SelectByIndex(i)) continue;
            if(m_pos.Symbol() != Symbol() || m_pos.Magic() != (ulong)m_magic) continue;
            if(m_pos.PositionType() != POSITION_TYPE_BUY) continue;
            if(MathAbs(m_pos.TakeProfit() - tpPrice) > symb.Point() * 2)
               m_trade.PositionModify(m_pos.Ticket(), m_pos.StopLoss(), tpPrice);
         }
      }
      if(totalLotSell > 0)
      {
         avgSellPrice /= totalLotSell;
         double tpPrice = avgSellPrice - ТейкПрофит * symb.Point();
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            if(!m_pos.SelectByIndex(i)) continue;
            if(m_pos.Symbol() != Symbol() || m_pos.Magic() != (ulong)m_magic) continue;
            if(m_pos.PositionType() != POSITION_TYPE_SELL) continue;
            if(MathAbs(m_pos.TakeProfit() - tpPrice) > symb.Point() * 2)
               m_trade.PositionModify(m_pos.Ticket(), m_pos.StopLoss(), tpPrice);
         }
      }
   }

   // FIX A: единый ПартиалПроцентTP для BUY и SELL
   void ManagePartialCloses(int buys, int sells)
   {
      if(buys > 1)
      {
         double avgBuyPrice = 0, totalLotBuy = 0;
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            if(m_pos.SelectByIndex(i) && m_pos.Magic() == (ulong)m_magic &&
               m_pos.PositionType() == POSITION_TYPE_BUY)
            { avgBuyPrice += m_pos.PriceOpen() * m_pos.Volume(); totalLotBuy += m_pos.Volume(); }
         }
         if(totalLotBuy > 0)
         {
            avgBuyPrice /= totalLotBuy;
            double partialTpPrice = avgBuyPrice + (ТейкПрофит * ПартиалПроцентTP / 100.0) * symb.Point();
            for(int i = PositionsTotal() - 1; i >= 0; i--)
            {
               if(!(m_pos.SelectByIndex(i) && m_pos.Magic() == (ulong)m_magic &&
                    m_pos.PositionType() == POSITION_TYPE_BUY)) continue;
               if(symb.Bid() >= partialTpPrice && m_pos.Profit() > 0)
               { m_trade.PositionClose(m_pos.Ticket()); break; }
            }
         }
      }
      if(sells > 1)
      {
         double avgSellPrice = 0, totalLotSell = 0;
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            if(m_pos.SelectByIndex(i) && m_pos.Magic() == (ulong)m_magic &&
               m_pos.PositionType() == POSITION_TYPE_SELL)
            { avgSellPrice += m_pos.PriceOpen() * m_pos.Volume(); totalLotSell += m_pos.Volume(); }
         }
         if(totalLotSell > 0)
         {
            avgSellPrice /= totalLotSell;
            double partialTpPrice = avgSellPrice - (ТейкПрофит * ПартиалПроцентTP / 100.0) * symb.Point();
            for(int i = PositionsTotal() - 1; i >= 0; i--)
            {
               if(!(m_pos.SelectByIndex(i) && m_pos.Magic() == (ulong)m_magic &&
                    m_pos.PositionType() == POSITION_TYPE_SELL)) continue;
               if(symb.Ask() <= partialTpPrice && m_pos.Profit() > 0)
               { m_trade.PositionClose(m_pos.Ticket()); break; }
            }
         }
      }
   }

   void ManageBreakeven(int buys, int sells)
   {
      if(buys > 0)
      {
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            if(!(m_pos.SelectByIndex(i) && m_pos.Magic() == (ulong)m_magic &&
                 m_pos.PositionType() == POSITION_TYPE_BUY)) continue;
            double bePrice = m_pos.PriceOpen() + BreakevenBuffer * symb.Point();
            if(symb.Bid() >= bePrice && m_pos.StopLoss() < bePrice)
               m_trade.PositionModify(m_pos.Ticket(), bePrice, m_pos.TakeProfit());
         }
      }
      if(sells > 0)
      {
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            if(!(m_pos.SelectByIndex(i) && m_pos.Magic() == (ulong)m_magic &&
                 m_pos.PositionType() == POSITION_TYPE_SELL)) continue;
            double bePrice = m_pos.PriceOpen() - BreakevenBuffer * symb.Point();
            if(symb.Ask() <= bePrice && (m_pos.StopLoss() == 0 || m_pos.StopLoss() > bePrice))
               m_trade.PositionModify(m_pos.Ticket(), bePrice, m_pos.TakeProfit());
         }
      }
   }
};

CGridStrategy Strat_Hilo;
CGridStrategy Strat_15;
CGridStrategy Strat_16;

CPositionInfo g_pos;

//+------------------------------------------------------------------+
//| ГЛОБАЛЬНОЕ ЗАКРЫТИЕ                                              |
//+------------------------------------------------------------------+
double GetGlobalProfit()
{
   double totalProfit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(g_pos.SelectByTicket(ticket) && g_pos.Symbol() == Symbol())
         totalProfit += g_pos.Profit();
   }
   return totalProfit;
}

void CheckGlobalCloseConditions()
{
   double globalProfit = GetGlobalProfit();
   bool shouldClose = false;

   if(UseGlobalCloseByMoney && globalProfit >= GlobalCloseMoney)
   {
      Print("ГЛОБАЛЬНОЕ ЗАКРЫТИЕ: $", DoubleToString(globalProfit, 2),
            " >= цель $", DoubleToString(GlobalCloseMoney, 2));
      shouldClose = true;
   }
   if(UseGlobalCloseByPercent && !shouldClose)
   {
      double targetProfit = acc.Balance() * GlobalClosePercent / 100.0;
      if(globalProfit >= targetProfit)
      {
         Print("ГЛОБАЛЬНОЕ ЗАКРЫТИЕ: ", DoubleToString(globalProfit, 2),
               " >= ", DoubleToString(GlobalClosePercent, 2), "% от баланса");
         shouldClose = true;
      }
   }

   if(shouldClose) CloseAllGlobalPositions();
}

void CloseAllGlobalPositions()
{
   CTrade trade;
   trade.SetTypeFillingBySymbol(Symbol());
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!g_pos.SelectByTicket(ticket)) continue;
      if(g_pos.Symbol() != Symbol())    continue;
      trade.PositionClose(ticket);
   }
   // FIX B: синхронизация с локом и handoff
   if(g_lock_active)            { g_lock_active = false; Print("Global close: lock state cleared."); }
   g_waiting_recovery_check = false;
   if(UseRecoveryHandoff && g_handoff_halted)
      HandoffSetHalt(false);
}

//+------------------------------------------------------------------+
//| MA / ATR helpers                                                 |
//+------------------------------------------------------------------+
bool InitTrendFilters()
{
   // LEGACY 3-MA фильтр
   if(UseТрендФильтр && !UseSTFilter)
   {
      g_ma_fast_handle = iMA(Symbol(), TrendTF, МА_Быстрая, 0, МА_Метод, МА_Цена);
      g_ma_mid_handle  = iMA(Symbol(), TrendTF, МА_Средняя, 0, МА_Метод, МА_Цена);
      g_ma_slow_handle = iMA(Symbol(), TrendTF, МА_Медленная, 0, МА_Метод, МА_Цена);
      if(g_ma_fast_handle == INVALID_HANDLE ||
         g_ma_mid_handle  == INVALID_HANDLE ||
         g_ma_slow_handle == INVALID_HANDLE)
      { Print("ERROR: MA handles"); return false; }
   }

   // SuperTrend LTF
   if(UseSTFilter)
   {
      g_st_ltf_handle = iCustom(Symbol(), ST_TF, STIndicatorName,
                                STAtrLength, STBaseMultiplier,
                                1.0, 0.5, true,          // NoiseThreshold, ExpansionAlpha, EvasionPersist
                                false, 5, 30, 10,        // Adaptive off, min/max/effLen
                                false, PERIOD_H1, 10, 3.0, true, true, CORNER_RIGHT_UPPER, // HTF off inside indicator (we do our own HTF)
                                true, true, 233, 234,    // ShowSignals, ColorCandles, ArrowCodes
                                true, 0, 20, 0.15, 1.50, 241, 242, 10,  // FBG defaults
                                true, true, 251, true, true,             // FBG trend/cross/alert
                                true, true, true, "alert.wav", false, false // alerts
                                );
      if(g_st_ltf_handle == INVALID_HANDLE)
      {
         // Попытка загрузить с минимальными параметрами (если кастомный набор не подходит)
         g_st_ltf_handle = iCustom(Symbol(), ST_TF, STIndicatorName);
         if(g_st_ltf_handle == INVALID_HANDLE)
         { Print("ERROR: ST LTF iCustom handle failed for ", STIndicatorName); return false; }
      }

      // SuperTrend HTF (отдельный экземпляр индикатора на старшем ТФ)
      if(UseSTHTF)
      {
         g_st_htf_handle = iCustom(Symbol(), ST_HTF, STIndicatorName,
                                   STHtfAtrLength, STHtfMultiplier,
                                   1.0, 0.5, true,
                                   false, 5, 30, 10,
                                   false, PERIOD_H1, 10, 3.0, true, true, CORNER_RIGHT_UPPER,
                                   true, true, 233, 234,
                                   true, 0, 20, 0.15, 1.50, 241, 242, 10,
                                   true, true, 251, true, true,
                                   true, true, true, "alert.wav", false, false
                                   );
         if(g_st_htf_handle == INVALID_HANDLE)
         {
            g_st_htf_handle = iCustom(Symbol(), ST_HTF, STIndicatorName);
            if(g_st_htf_handle == INVALID_HANDLE)
            { Print("ERROR: ST HTF iCustom handle failed for ", STIndicatorName); return false; }
         }
      }
   }
   return true;
}

double GetMA(int handle)
{
   if(handle == INVALID_HANDLE) return 0.0;
   double buf[1];
   return (CopyBuffer(handle, 0, 1, 1, buf) > 0) ? buf[0] : 0.0;
}

double GetGridStepPoints()
{
   if(!UseATRGrid || g_atr_handle == INVALID_HANDLE) return ШагСетки;
   double atr_buf[1];
   if(CopyBuffer(g_atr_handle, 0, 0, 1, atr_buf) <= 0) return ШагСетки;
   double atr_points = atr_buf[0] / symb.Point();
   double step_points = atr_points * ATR_Multiplier;
   return (step_points > 0.0) ? step_points : ШагСетки;
}

//+------------------------------------------------------------------+
//| GUI                                                              |
//+------------------------------------------------------------------+
void CreateLabel(const string name, int x, int y, const string text,
                 color clr, int fontsize, ENUM_BASE_CORNER corner = CORNER_RIGHT_UPPER)
{
   if(ObjectFind(0, name) == -1) ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString (0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontsize);
   ObjectSetString (0, name, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
}

void CreatePanelBackground(const string name, int x, int y, int w, int h,
                           color back, ENUM_BASE_CORNER corner = CORNER_RIGHT_UPPER)
{
   if(ObjectFind(0, name) == -1) ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, back);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_COLOR, back);
}

int GetStaticPanelWidth() { return 400; }
int CalculatePanelHeight(int numLines, int lineHeight, int headerMargin, int padding)
{
   int height = padding * 2;
   if(numLines >= 1) height += lineHeight + headerMargin;
   if(numLines > 1)  height += (numLines - 1) * lineHeight;
   return height;
}
int GetStaticPanelHeight() { return CalculatePanelHeight(7, GUI_StepY, Panel_HeaderMargin, Panel_Padding); }

// FIX D: удаляем ТОЛЬКО свои объекты по префиксу
void DeleteOwnPanelObjects()
{
   long total = ObjectsTotal(0);
   for(long i = total - 1; i >= 0; --i)
   {
      string n = ObjectName(0, (int)i);
      if(StringFind(n, "AlicePanel") == 0) ObjectDelete(0, n);
   }
   g_panel_created = false;
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   double gv_val = 0.0;
   if(!GlobalVariableCheck(g_license_gv_name))
   {
      gv_val = (double)TimeCurrent();
      GlobalVariableSet(g_license_gv_name, gv_val);
   }
   else
      gv_val = GlobalVariableGet(g_license_gv_name);

   datetime first_start = (datetime)gv_val;
   g_trial_expiry = first_start + g_trial_days * 24 * 60 * 60;

   if(TimeCurrent() > g_trial_expiry)
   {
      MessageBox("Пробная лицензия истекла", "Алиса MT5", MB_ICONSTOP);
      return INIT_FAILED;
   }
   g_license_ok = true;

   if(!symb.Name(Symbol())) return INIT_FAILED;
   symb.RefreshRates();

   if(!InitTrendFilters()) return INIT_FAILED;

   if(UseATRGrid)
   {
      g_atr_handle = iATR(Symbol(), ATR_TF, ATR_Period);
      if(g_atr_handle == INVALID_HANDLE) return INIT_FAILED;
   }

   Strat_Hilo.Init(MagicHilo, МаксСделокHilo, ИспользоватьHilo,
                   Hilo_RSI_TF_Entry, Hilo_RSI_TF_Filter, Hilo_RSI_Period,
                   Hilo_RSI_BuyLevel, Hilo_RSI_SellLevel,
                   Hilo_WPR_TF_Entry, Hilo_WPR_TF_Filter, Hilo_WPR_Period,
                   Hilo_WPR_BuyLevel, Hilo_WPR_SellLevel,
                   Hilo_SignalType, КомментарийHilo, Hilo_Mode);

   Strat_15.Init(Magic15, МаксСделок15, Использовать15,
                 S15_RSI_TF_Entry, S15_RSI_TF_Filter, S15_RSI_Period,
                 S15_RSI_BuyLevel, S15_RSI_SellLevel,
                 S15_WPR_TF_Entry, S15_WPR_TF_Filter, S15_WPR_Period,
                 S15_WPR_BuyLevel, S15_WPR_SellLevel,
                 Strat15_SignalType, Комментарий15, S15_Mode);

   Strat_16.Init(Magic16, МаксСделок16, Использовать16,
                 S16_RSI_TF_Entry, S16_RSI_TF_Filter, S16_RSI_Period,
                 S16_RSI_BuyLevel, S16_RSI_SellLevel,
                 S16_WPR_TF_Entry, S16_WPR_TF_Filter, S16_WPR_Period,
                 S16_WPR_BuyLevel, S16_WPR_SellLevel,
                 Strat16_SignalType, Комментарий16, S16_Mode);

   g_last_grid_bar_time = iTime(Symbol(), GridTF, 0);

   // FIX F: warning при netting + лок
   ENUM_ACCOUNT_MARGIN_MODE mm = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(mm == ACCOUNT_MARGIN_MODE_RETAIL_NETTING && UseDrawdownLock && !UseRecoveryHandoff)
      Print("WARNING: netting account + UseDrawdownLock=true. ",
            "Встречная позиция будет схлопывать существующую нетто. ",
            "Рекомендуется UseRecoveryHandoff=true.");

   // HANDOFF: восстановление состояния после рестарта терминала
   g_handoff_halted = (GlobalVariableCheck(GV_HANDOFF_HALT) &&
                       GlobalVariableGet(GV_HANDOFF_HALT) > 0.5);
   if(g_handoff_halted)
      Print("HANDOFF: state restored from GV — Алиса halted.");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   DeleteOwnPanelObjects();   // FIX D
   Comment("");

   // Освобождаем ST handles
   if(g_st_ltf_handle != INVALID_HANDLE) { IndicatorRelease(g_st_ltf_handle); g_st_ltf_handle = INVALID_HANDLE; }
   if(g_st_htf_handle != INVALID_HANDLE) { IndicatorRelease(g_st_htf_handle); g_st_htf_handle = INVALID_HANDLE; }

   if(g_lock_active)
   {
      // FIX C: закрытие лока опционально
      if(CloseLockOnDeinit)
      {
         CloseLockPosition();
         Print("Lock closed on EA deinit (CloseLockOnDeinit=true).");
      }
      else
      {
         Print("WARNING: lock active but CloseLockOnDeinit=false — лок остался на счёте.");
      }
   }

   // HANDOFF: GV сохраняем — Recovery должен иметь возможность дочистить
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!g_license_ok)            return;
   if(!symb.RefreshRates())     return;
   if(ИспользоватьОстановку && CheckFloatingLoss()) return;

   UpdateTrendFlags();
   UpdateNewsFilter();
   CheckAndManageDrawdownLock();
   CheckGlobalCloseConditions();

   bool is_new_grid_bar = false;
   datetime cur_bar_time = iTime(Symbol(), GridTF, 0);
   if(cur_bar_time > 0 && cur_bar_time != g_last_grid_bar_time)
   {
      g_last_grid_bar_time = cur_bar_time;
      is_new_grid_bar = true;
   }

   Strat_Hilo.OnTickProcess(is_new_grid_bar);
   Strat_15.OnTickProcess(is_new_grid_bar);
   Strat_16.OnTickProcess(is_new_grid_bar);

   UpdateInfo();
}

bool CheckFloatingLoss()
{
   if(acc.Profit() < -MathAbs(МаксПлавающийУбыток))
   {
      Comment("\n МАКСИМАЛЬНЫЙ УБЫТОК ДОСТИГНУТ! ТОРГОВЛЯ ОСТАНОВЛЕНА.");
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| UpdateInfo                                                       |
//+------------------------------------------------------------------+
void UpdateInfo()
{
   if(!ПоказыватьGUI)
   {
      if(g_panel_created) DeleteOwnPanelObjects();
      Comment("");
      return;
   }

   ENUM_BASE_CORNER corner = Panel_RightCorner ? CORNER_RIGHT_UPPER : CORNER_LEFT_UPPER;
   int baseX = GUI_X, baseY = GUI_Y, lineStep = GUI_StepY;

   string trendStatus = "---";
   if(UseSTFilter)
   {
      if(g_st_ltf_trend == 1 && g_trend_buy_allowed)       trendStatus = "ST:↑BUY";
      else if(g_st_ltf_trend == -1 && g_trend_sell_allowed) trendStatus = "ST:↓SELL";
      else if(g_st_evasive)                                 trendStatus = "ST:~EVASION";
      else if(g_st_flip_bars < STMinBarsForFlip)            trendStatus = "ST:FLIP(" + IntegerToString(g_st_flip_bars) + ")";
      else                                                  trendStatus = "ST:WAIT";

      // Добавляем HTF если включён
      if(UseSTHTF)
      {
         string htfS = (g_st_htf_trend > 0) ? "H↑" : (g_st_htf_trend < 0) ? "H↓" : "H-";
         trendStatus += "|" + htfS;
      }
   }
   else if(UseТрендФильтр)
   {
      if(IsTrendBullish())      trendStatus = "MA:↑BUY";
      else if(IsTrendBearish()) trendStatus = "MA:↓SELL";
      else                      trendStatus = "MA:→ФЛЭТ";
   }

   // News status
   string newsStatus = "";
   if(UseNewsFilter && g_news_block_entry)
      newsStatus = " | NEWS:" + g_news_block_reason;

   double globalProfit = GetGlobalProfit();
   string lockStatus = GetLockStatus();

   string head = "АлисА v5.3 | Bal: " + DoubleToString(acc.Balance(), 2) +
                 " Eq: " + DoubleToString(acc.Equity(), 2) +
                 " [" + trendStatus + "]" + newsStatus;

   string line1 = КомментарийHilo + " B:" + IntegerToString(Strat_Hilo.m_cntBuy) +
                  " S:" + IntegerToString(Strat_Hilo.m_cntSell) +
                  " P:" + DoubleToString(Strat_Hilo.m_floatingProfit, 2);
   string line2 = Комментарий15 + " B:" + IntegerToString(Strat_15.m_cntBuy) +
                  " S:" + IntegerToString(Strat_15.m_cntSell) +
                  " P:" + DoubleToString(Strat_15.m_floatingProfit, 2);
   string line3 = Комментарий16 + " B:" + IntegerToString(Strat_16.m_cntBuy) +
                  " S:" + IntegerToString(Strat_16.m_cntSell) +
                  " P:" + DoubleToString(Strat_16.m_floatingProfit, 2);

   string globalStatus = "ГЛОБАЛ: $" + DoubleToString(globalProfit, 2);
   if(UseGlobalCloseByMoney)   globalStatus += " / Цель: $" + DoubleToString(GlobalCloseMoney, 2);
   if(UseGlobalCloseByPercent) globalStatus += " / Цель: " + DoubleToString(GlobalClosePercent, 2) + "%";

   if(!g_panel_created)
   {
      CreatePanelBackground("AlicePanelBG", baseX - 10, baseY - 10,
                            GetStaticPanelWidth(), GetStaticPanelHeight(),
                            Panel_BackColor, corner);
      int y = baseY;
      CreateLabel("AlicePanel_Line0", baseX, y, head,         GUI_ColorMain,   GUI_FontSize + 1, corner); y += lineStep + Panel_HeaderMargin;
      CreateLabel("AlicePanel_Line1", baseX, y, line1,        GUI_ColorHilo,   GUI_FontSize, corner); y += lineStep;
      CreateLabel("AlicePanel_Line2", baseX, y, line2,        GUI_Color15,     GUI_FontSize, corner); y += lineStep;
      CreateLabel("AlicePanel_Line3", baseX, y, line3,        GUI_Color16,     GUI_FontSize, corner); y += lineStep;
      CreateLabel("AlicePanel_Global",baseX, y, globalStatus, GUI_ColorGlobal, GUI_FontSize, corner); y += lineStep;
      CreateLabel("AlicePanel_Lock",  baseX, y, lockStatus,   GUI_ColorLock,   GUI_FontSize, corner);
      g_panel_created = true;
   }
   else
   {
      ObjectSetString(0, "AlicePanel_Line0", OBJPROP_TEXT, head);
      ObjectSetString(0, "AlicePanel_Line1", OBJPROP_TEXT, line1);
      ObjectSetString(0, "AlicePanel_Line2", OBJPROP_TEXT, line2);
      ObjectSetString(0, "AlicePanel_Line3", OBJPROP_TEXT, line3);
      ObjectSetString(0, "AlicePanel_Global",OBJPROP_TEXT, globalStatus);
      ObjectSetString(0, "AlicePanel_Lock",  OBJPROP_TEXT, lockStatus);
   }
}

//+------------------------------------------------------------------+
//| Хелперы тренда для GUI                                           |
//+------------------------------------------------------------------+
bool IsTrendBullish()
{
   if(!UseТрендФильтр) return true;
   double fast = GetMA(g_ma_fast_handle), mid = GetMA(g_ma_mid_handle), slow = GetMA(g_ma_slow_handle);
   return (fast > mid && mid > slow);
}
bool IsTrendBearish()
{
   if(!UseТрендФильтр) return true;
   double fast = GetMA(g_ma_fast_handle), mid = GetMA(g_ma_mid_handle), slow = GetMA(g_ma_slow_handle);
   return (fast < mid && mid < slow);
}
//+------------------------------------------------------------------+
