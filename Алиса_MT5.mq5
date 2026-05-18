//+------------------------------------------------------------------+
//|                                             Алиса_MT5.mq5        |
//|   3 стратегии (RSI/WPR/RSI+WPR) + ТРЕНД-ФИЛЬТР + ATR EA          |
//|   Усреднение ТОЛЬКО на новой свече GridTF                        |
//|   + ГЛОБАЛЬНОЕ ЗАКРЫТИЕ ПО ДЕНЬГАМ/ПРОЦЕНТАМ                    |
//|   + ПЕРЕКЛЮЧЕНИЕ РЕЖИМОВ RSI/WPR/СОВМЕСТНО для каждой стратегии |
//|   + ЗАКРЫТИЕ ОРДЕРОВ ПО СМЕНЕ ТРЕНДА                            |
//|   + ЛОКИРОВАНИЕ ПО ПРОСАДКЕ ОТ БАЛАНСА (НОВОЕ)                  |
//+------------------------------------------------------------------+
#property copyright "АлисА v5.1"
#property link      "ZMA"
#property version   "5.1"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

CAccountInfo   acc;
CSymbolInfo    symb;
CTrade         g_global_trade;

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

input group "=== ФИЛЬТР ПО ТРЕНДУ (3 МА) ==="
input bool   UseТрендФильтр         = true;
input ENUM_TIMEFRAMES TrendTF       = PERIOD_H1;
input int    МА_Быстрая             = 133;
input int    МА_Средняя             = 233;
input int    МА_Медленная           = 333;
input ENUM_MA_METHOD МА_Метод       = MODE_EMA;
input ENUM_APPLIED_PRICE МА_Цена    = PRICE_CLOSE;

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

// === ГЛОБАЛЬНОЕ ЗАКРЫТИЕ ВСЕХ ОРДЕРОВ ===
input group "=== ГЛОБАЛЬНОЕ ЗАКРЫТИЕ (ВСЕ ОРДЕРА) ==="
input bool   UseGlobalCloseByMoney  = true;      // Закрывать по деньгам
input double GlobalCloseMoney       = 100.0;    // Прибыль в $ для закрытия всех
input bool   UseGlobalCloseByPercent = false;   // Закрывать по процентам
input double GlobalClosePercent     = 2.0;      // Процент прибыли от баланса

// === ЛОКИРОВАНИЕ ПО ПРОСАДКЕ ОТ БАЛАНСА ===
input group "=== ЛОКИРОВАНИЕ ПО ПРОСАДКЕ (ОТ БАЛАНСА) ==="
input bool   UseDrawdownLock        = true;      // Использовать локирование
input double LockDrawdownPercent    = 5.0;       // Просадка от баланса для лока (%)
input int    LockDurationMinutes    = 30;        // Длительность паузы торговли (мин)
input int    RecoveryCheckMinutes   = 5;         // Проверка через N минут после закрытия лока
input bool   AutoReLockIfNoRecovery = true;      // Открыть новый лок если просадка не снизилась

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
input bool   ЧастичноеЗакрытие     = false;
input double ПрибыльЧастичного     = 150.0;
input int    ПроцентЧастичного     = 50;
input bool   UseBreakeven           = false;
input double BreakevenBuffer        = 5.0;
input bool   EnableDetailedLog      = false;

int g_ma_fast_handle  = INVALID_HANDLE;
int g_ma_mid_handle   = INVALID_HANDLE;
int g_ma_slow_handle  = INVALID_HANDLE;

int g_atr_handle      = INVALID_HANDLE;

datetime g_last_grid_bar_time = 0;

// Флаги разрешения торговли
bool g_trend_buy_allowed  = false;
bool g_trend_sell_allowed = false;

// Отслеживание предыдущего состояния тренда для обнаружения смены
int g_last_trend_state = 0;  // 1=BULL, -1=BEAR, 0=FLAT

// === ПЕРЕМЕННЫЕ ДЛЯ ЛОКИРОВАНИЯ ПО ПРОСАДКЕ ===
bool       g_lock_active = false;           // Лок активен (торговля остановлена)
datetime   g_lock_start_time = 0;           // Время начала лока
datetime   g_lock_end_time = 0;             // Время окончания лока (расчетное)
double     g_lock_start_balance = 0;        // Баланс при начале лока
double     g_lock_max_drawdown = 0;         // Максимальная просадка за период лока
int        g_total_locks = 0;               // Счетчик локов
bool       g_waiting_recovery_check = false;  // Ожидаем проверку восстановления
datetime   g_recovery_check_time = 0;       // Время проверки восстановления

//+------------------------------------------------------------------+
//| ФУНКЦИИ ЛОКИРОВАНИЯ ПО ПРОСАДКЕ ОТ БАЛАНСА                      |
//+------------------------------------------------------------------+

// Получить текущую просадку от баланса в процентах
double GetCurrentDrawdownPercent()
{
   double balance = acc.Balance();
   double equity = acc.Equity();
   
   if(balance <= 0) return 0;
   
   // Просадка = насколько эквити ниже баланса
   double drawdown = balance - equity;
   if(drawdown <= 0) return 0;
   
   return (drawdown / balance) * 100.0;
}

// Основная функция управления локом
void CheckAndManageDrawdownLock()
{
   if(!UseDrawdownLock) return;
   
   datetime now = TimeCurrent();
   double current_dd = GetCurrentDrawdownPercent();
   
   // === СЛУЧАЙ 1: Лок не активен, проверяем необходимость активации ===
   if(!g_lock_active && !g_waiting_recovery_check)
   {
      if(current_dd >= LockDrawdownPercent)
      {
         ActivateLock();
      }
      return;
   }
   
   // === СЛУЧАЙ 2: Лок активен, проверяем время ===
   if(g_lock_active)
   {
      // Обновляем максимальную просадку за период лока
      if(current_dd > g_lock_max_drawdown)
         g_lock_max_drawdown = current_dd;
      
      // Проверяем, не истекло ли время лока
      if(now >= g_lock_end_time)
      {
         // Время истекло - закрываем лок
         CloseLockPosition();
         g_lock_active = false;
         
         // Устанавливаем время проверки восстановления
         g_waiting_recovery_check = true;
         g_recovery_check_time = now + RecoveryCheckMinutes * 60;
         
         Print("⏰ Время лока истекло (", LockDurationMinutes, " мин). Лок закрыт. " +
               "Ожидание проверки восстановления через ", RecoveryCheckMinutes, " мин...");
      }
      return;
   }
   
   // === СЛУЧАЙ 3: Ожидаем проверку восстановления ===
   if(g_waiting_recovery_check)
   {
      // Проверяем, не пришло ли время проверки
      if(now >= g_recovery_check_time)
      {
         g_waiting_recovery_check = false;
         
         // Проверяем, восстановилась ли просадка
         double dd_now = GetCurrentDrawdownPercent();
         
         // Если просадка всё еще высокая (не снизилась значительно) - открываем новый лок
         if(AutoReLockIfNoRecovery && dd_now >= LockDrawdownPercent * 0.8) // 80% от порога
         {
            Print("⚠️ Просадка не восстановилась! Текущая: ", DoubleToString(dd_now, 2), 
                  "% | Открываем новый лок...");
            ActivateLock();
         }
         else
         {
            Print("✅ Просадка восстановилась: ", DoubleToString(dd_now, 2), 
                  "%. Торговля продолжается.");
         }
      }
   }
}

// Активация локирования (полный стоп на торговлю + открытие лок-ордера)
void ActivateLock()
{
   datetime now = TimeCurrent();
   
   g_lock_active = true;
   g_lock_start_time = now;
   g_lock_end_time = now + LockDurationMinutes * 60;
   g_lock_start_balance = acc.Balance();
   g_lock_max_drawdown = GetCurrentDrawdownPercent();
   g_total_locks++;
   
   Print("🔒 ЛОК АКТИВИРОВАН #", g_total_locks, "! Просадка: ", 
         DoubleToString(g_lock_max_drawdown, 2), "% | Торговля ОСТАНОВЛЕНА на ", 
         LockDurationMinutes, " минут");
   
   // Открываем локирующий ордер
   OpenLockPosition();
}

// Открытие локирующей позиции (встречная нетто-позиция)
void OpenLockPosition()
{
   // Определяем нетто-позицию по всем стратегиям
   double net_position = 0;
   CPositionInfo pos;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(pos.SelectByTicket(ticket))
      {
         if(pos.Symbol() == Symbol())
         {
            // Только основные стратегии (не локи)
            int magic = (int)pos.Magic();
            if(magic == MagicHilo || magic == Magic15 || magic == Magic16)
            {
               if(pos.PositionType() == POSITION_TYPE_BUY)
                  net_position += pos.Volume();
               else
                  net_position -= pos.Volume();
            }
         }
      }
   }
   
   if(net_position == 0)
   {
      Print("⚠️ Нет открытых позиций для локирования");
      return;
   }
   
   // Открываем встречную позицию
   ENUM_ORDER_TYPE lock_type = (net_position > 0) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   double lock_volume = MathAbs(net_position);
   
   // Нормализуем объем
   double min_lot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   double step_lot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
   
   lock_volume = MathFloor(lock_volume / step_lot) * step_lot;
   if(lock_volume < min_lot) lock_volume = min_lot;
   if(lock_volume > max_lot) lock_volume = max_lot;
   
   string comment = "LOCK#" + IntegerToString(g_total_locks);
   
   CTrade trade;
   trade.SetExpertMagicNumber(999999); // Особый магик для локов
   trade.SetTypeFillingBySymbol(Symbol());
   trade.SetDeviationInPoints((ulong)Проскальзывание);
   
   bool result = false;
   if(lock_type == ORDER_TYPE_SELL)
      result = trade.Sell(lock_volume, Symbol(), 0, 0, 0, comment);
   else
      result = trade.Buy(lock_volume, Symbol(), 0, 0, 0, comment);
   
   if(result && trade.ResultRetcode() == TRADE_RETCODE_DONE)
   {
      Print("✅ Лок-ордер открыт: #", trade.ResultOrder(), " Объём: ", lock_volume,
            " Тип: ", (lock_type == ORDER_TYPE_BUY ? "BUY" : "SELL"));
   }
   else
   {
      Print("❌ Ошибка открытия лока: ", trade.ResultRetcodeDescription());
   }
}

// Закрытие локирующей позиции по истечении времени
void CloseLockPosition()
{
   CTrade trade;
   trade.SetTypeFillingBySymbol(Symbol());
   CPositionInfo pos;
   
   int closed_count = 0;
   
   // Закрываем ВСЕ позиции с магиком лока
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(pos.SelectByTicket(ticket))
      {
         if(pos.Symbol() == Symbol() && pos.Magic() == 999999)
         {
            if(StringFind(pos.Comment(), "LOCK#") != -1)
            {
               trade.PositionClose(ticket);
               if(trade.ResultRetcode() == TRADE_RETCODE_DONE)
               {
                  closed_count++;
                  Print("🔓 Лок-ордер #", ticket, " закрыт");
               }
            }
         }
      }
   }
   
   if(closed_count == 0)
   {
      Print("⚠️ Лок-ордеры для закрытия не найдены");
   }
   else
   {
      Print("🔓 Закрыто лок-ордеров: ", closed_count);
   }
}

// Проверка разрешения торговли (торговля запрещена во время лока)
bool IsTradingAllowed()
{
   if(!UseDrawdownLock) return true;
   return !g_lock_active; // Торговля запрещена только когда активен лок
}

// Получение статуса лока для GUI
string GetLockStatus()
{
   if(!UseDrawdownLock) return "Лок: OFF";
   
   if(g_lock_active)
   {
      int remaining = (int)(g_lock_end_time - TimeCurrent()) / 60;
      if(remaining < 0) remaining = 0;
      
      return "🔒 ЛОК #" + IntegerToString(g_total_locks) + 
             " | Осталось: " + IntegerToString(remaining) + "мин | " +
             "Просадка: " + DoubleToString(GetCurrentDrawdownPercent(), 2) + "%";
   }
   
   if(g_waiting_recovery_check)
   {
      int wait_min = (int)(g_recovery_check_time - TimeCurrent()) / 60;
      if(wait_min < 0) wait_min = 0;
      
      return "⏳ Проверка через: " + IntegerToString(wait_min) + "мин | " +
             "Просадка: " + DoubleToString(GetCurrentDrawdownPercent(), 2) + "%";
   }
   
   return "Лок: Готов | Просадка: " + DoubleToString(GetCurrentDrawdownPercent(), 2) + "%";
}

//+------------------------------------------------------------------+
//| ФУНКЦИЯ ОБНОВЛЕНИЯ ФЛАГОВ ТРЕНДА                                |
//+------------------------------------------------------------------+
void UpdateTrendFlags()
{
   g_trend_buy_allowed  = false;
   g_trend_sell_allowed = false;
   
   int current_trend = 0;

   if(!UseТрендФильтр)
   {
      g_trend_buy_allowed  = true;
      g_trend_sell_allowed = true;
      current_trend = 1;
   }
   else
   {
      double fast = GetMA(g_ma_fast_handle);
      double mid  = GetMA(g_ma_mid_handle);
      double slow = GetMA(g_ma_slow_handle);

      if(fast > mid && mid > slow)
      {
         g_trend_buy_allowed  = true;
         g_trend_sell_allowed = false;
         current_trend = 1;
      }
      else if(fast < mid && mid < slow)
      {
         g_trend_buy_allowed  = false;
         g_trend_sell_allowed = true;
         current_trend = -1;
      }
      else
      {
         g_trend_buy_allowed  = false;
         g_trend_sell_allowed = false;
         current_trend = 0;
      }

      if(ForbidAlisaTradingInFlat && current_trend == 0)
      {
         g_trend_buy_allowed  = false;
         g_trend_sell_allowed = false;
      }
   }

   if(CloseOnTrendChange && g_last_trend_state != 0 && current_trend != g_last_trend_state)
   {
      if(g_last_trend_state == 1 && current_trend == -1 && CloseBuyOnBearTrend)
      {
         CloseBuyPositions();
         Print("[TREND] Смена тренда BULL->BEAR: закрыли BUY позиции");
      }
      
      if(g_last_trend_state == -1 && current_trend == 1 && CloseSellOnBullTrend)
      {
         CloseSellPositions();
         Print("[TREND] Смена тренда BEAR->BULL: закрыли SELL позиции");
      }

      if(current_trend == 0 && CloseOnFlat)
      {
         CloseAllStrategyPositions();
         Print("[TREND] Обнаружен ФЛЭТ: закрыли ВСЕ позиции");
      }

      if(g_last_trend_state == 0 && current_trend != 0)
      {
         if(current_trend == 1 && CloseSellOnBullTrend)
         {
            CloseSellPositions();
            Print("[TREND] Выход из ФЛЭТА в BULL: закрыли SELL позиции");
         }
         else if(current_trend == -1 && CloseBuyOnBearTrend)
         {
            CloseBuyPositions();
            Print("[TREND] Выход из ФЛЭТА в BEAR: закрыли BUY позиции");
         }
      }
   }

   g_last_trend_state = current_trend;
}

//+------------------------------------------------------------------+
//| ФУНКЦИИ ЗАКРЫТИЯ ПОЗИЦИЙ ПО ТРЕНДУ                              |
//+------------------------------------------------------------------+
void CloseBuyPositions()
{
   CTrade trade;
   trade.SetTypeFillingBySymbol(Symbol());
   CPositionInfo pos;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(pos.SelectByTicket(ticket))
      {
         if(pos.Symbol() == Symbol() && pos.PositionType() == POSITION_TYPE_BUY)
         {
            int magic = (int)pos.Magic();
            if(magic == MagicHilo || magic == Magic15 || magic == Magic16)
            {
               trade.PositionClose(ticket);
            }
         }
      }
   }
}

void CloseSellPositions()
{
   CTrade trade;
   trade.SetTypeFillingBySymbol(Symbol());
   CPositionInfo pos;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(pos.SelectByTicket(ticket))
      {
         if(pos.Symbol() == Symbol() && pos.PositionType() == POSITION_TYPE_SELL)
         {
            int magic = (int)pos.Magic();
            if(magic == MagicHilo || magic == Magic15 || magic == Magic16)
            {
               trade.PositionClose(ticket);
            }
         }
      }
   }
}

void CloseAllStrategyPositions()
{
   CTrade trade;
   trade.SetTypeFillingBySymbol(Symbol());
   CPositionInfo pos;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(pos.SelectByTicket(ticket))
      {
         if(pos.Symbol() == Symbol())
         {
            int magic = (int)pos.Magic();
            if(magic == MagicHilo || magic == Magic15 || magic == Magic16)
            {
               trade.PositionClose(ticket);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| КЛАСС СТРАТЕГИИ (RSI/WPR/RSI+WPR)                              |
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
   
   int            m_signal_type;
   
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
   
public:
   int            m_cntBuy;
   int            m_cntSell;
   double         m_totalLotBuy;
   double         m_totalLotSell;
   double         m_floatingProfit;

   void Init(int magic, int max_trades, bool enable,
             ENUM_TIMEFRAMES tf_rsi_entry, ENUM_TIMEFRAMES tf_rsi_filter,
             int rsi_period, double rsi_buyLevel, double rsi_sellLevel,
             ENUM_TIMEFRAMES tf_wpr_entry, ENUM_TIMEFRAMES tf_wpr_filter,
             int wpr_period, double wpr_buyLevel, double wpr_sellLevel,
             ENUM_APPLIED_PRICE signal_type_param,
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
      
      if(signal_type_param == PRICE_CLOSE) 
         m_signal_type = 0;
      else if(signal_type_param == PRICE_OPEN)
         m_signal_type = 1;
      else
         m_signal_type = 2;

      m_trade.SetExpertMagicNumber(m_magic);
      m_trade.SetDeviationInPoints((ulong)Проскальзывание);
      m_trade.SetTypeFillingBySymbol(Symbol());
      m_trade.SetAsyncMode(false);

      m_rsi_entry_handle = iRSI(Symbol(), tf_rsi_entry, m_rsi_period, PRICE_CLOSE);
      if(m_rsi_entry_handle == INVALID_HANDLE)
      {
         Print("ERROR [", m_baseComment, "]: RSI entry");
         m_enabled = false;
         return;
      }

      m_rsi_filter_handle = iRSI(Symbol(), tf_rsi_filter, m_rsi_period, PRICE_CLOSE);
      if(m_rsi_filter_handle == INVALID_HANDLE)
      {
         Print("ERROR [", m_baseComment, "]: RSI filter");
         m_enabled = false;
         return;
      }
      
      m_wpr_entry_handle = iWPR(Symbol(), tf_wpr_entry, m_wpr_period);
      if(m_wpr_entry_handle == INVALID_HANDLE)
      {
         Print("ERROR [", m_baseComment, "]: WPR entry");
         m_enabled = false;
         return;
      }

      m_wpr_filter_handle = iWPR(Symbol(), tf_wpr_filter, m_wpr_period);
      if(m_wpr_filter_handle == INVALID_HANDLE)
      {
         Print("ERROR [", m_baseComment, "]: WPR filter");
         m_enabled = false;
         return;
      }
      
      m_buy_signal_sent  = false;
      m_sell_signal_sent = false;
      m_last_buy_time = m_last_sell_time = 0;
   }

   void OnTickProcess(bool is_new_grid_bar)
   {
      if(!m_enabled) return;
      
      // ПРОВЕРКА: если активен лок — торговля полностью запрещена
      if(!IsTradingAllowed()) return;

      m_cntBuy         = 0;
      m_cntSell        = 0;
      m_totalLotBuy    = 0.0;
      m_totalLotSell   = 0.0;
      m_floatingProfit = 0.0;
      
      m_last_buy_time = m_last_sell_time = 0;
      m_last_buy_price = m_last_sell_price = 0;
      m_last_buy_lot = m_last_sell_lot = 0;

      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(m_pos.SelectByIndex(i))
         {
            if(m_pos.Symbol() == Symbol() && m_pos.Magic() == m_magic)
            {
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

      bool buy_signal  = false;
      bool sell_signal = false;

      if(m_mode == 0)
      {
         buy_signal  = rsi_buy_signal;
         sell_signal = rsi_sell_signal;
      }
      else if(m_mode == 1)
      {
         buy_signal  = wpr_buy_signal;
         sell_signal = wpr_sell_signal;
      }
      else if(m_mode == 2)
      {
         buy_signal  = (rsi_buy_signal && wpr_buy_signal);
         sell_signal = (rsi_sell_signal && wpr_sell_signal);
      }

      if(РазрешитьBuy && m_cntBuy < m_max_trades && buy_signal && g_trend_buy_allowed)
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
            {
               double newLot = CalculateNextLot(m_last_buy_lot);
               OpenOrder(ORDER_TYPE_BUY, newLot, m_baseComment + " BUY grid");
            }
         }
      }
      else if(!buy_signal)
         m_buy_signal_sent = false;

      if(РазрешитьSell && m_cntSell < m_max_trades && sell_signal && g_trend_sell_allowed)
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
            {
               double newLot = CalculateNextLot(m_last_sell_lot);
               OpenOrder(ORDER_TYPE_SELL, newLot, m_baseComment + " SELL grid");
            }
         }
      }
      else if(!sell_signal)
         m_sell_signal_sent = false;

      ManageTakeProfitOptimized(m_cntBuy, m_cntSell);
      if(ЧастичноеЗакрытие)
         ManagePartialCloses(m_cntBuy, m_cntSell);
      if(UseBreakeven)
         ManageBreakeven(m_cntBuy, m_cntSell);
   }

private:
   double GetStartLot()
   {
      if(НачальныйЛот > 0)
         return NormalizeVolume(НачальныйЛот);
      
      double riskAmount = acc.Balance() * (РискПроцентов / 100.0);
      double tickValue  = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
      if(tickValue <= 0) tickValue = 1.0;
      
      double pipValue = tickValue * symb.Point();
      if(pipValue <= 0) pipValue = 0.0001;
      
      double maxRiskOnTrade = ШагСетки * pipValue;
      if(maxRiskOnTrade <= 0) maxRiskOnTrade = 0.001;
      
      double calculatedLot = riskAmount / maxRiskOnTrade;
      if(calculatedLot > МаксЛот)
         calculatedLot = МаксЛот;
      
      return NormalizeVolume(calculatedLot);
   }

   double GetRSI(int handle, int shift)
   {
      if(handle == INVALID_HANDLE) return 50.0;
      double buf[1];
      if(CopyBuffer(handle, 0, shift, 1, buf) > 0)
         return buf[0];
      return 50.0;
   }

   double GetWPR(int handle, int shift)
   {
      if(handle == INVALID_HANDLE) return -50.0;
      double buf[1];
      if(CopyBuffer(handle, 0, shift, 1, buf) > 0)
         return buf[0];
      return -50.0;
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
      
      if(nextLot > МаксЛот) 
         nextLot = МаксЛот;

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
      if(acc.FreeMargin() < required) return;

      double maxSpread = SymbolInfoDouble(Symbol(), SYMBOL_ASK) -
                         SymbolInfoDouble(Symbol(), SYMBOL_BID);
      if(maxSpread > 10000 * symb.Point()) return;

      double price = (type == ORDER_TYPE_BUY) ? symb.Ask() : symb.Bid();
      
      bool result = false;
      if(type == ORDER_TYPE_BUY)
         result = m_trade.Buy(volume, Symbol(), price, 0, 0, comment);
      else
         result = m_trade.Sell(volume, Symbol(), price, 0, 0, comment);
   }

   void ManageTakeProfitOptimized(int buys, int sells)
   {
      if(buys == 0 && sells == 0) return;
      
      double totalLotBuy = 0, totalLotSell = 0;
      double avgBuyPrice = 0, avgSellPrice = 0;
      
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(m_pos.SelectByIndex(i) && m_pos.Symbol() == Symbol() && m_pos.Magic() == m_magic)
         {
            if(m_pos.PositionType() == POSITION_TYPE_BUY)
            {
               avgBuyPrice += m_pos.PriceOpen() * m_pos.Volume();
               totalLotBuy += m_pos.Volume();
            }
            else if(m_pos.PositionType() == POSITION_TYPE_SELL)
            {
               avgSellPrice += m_pos.PriceOpen() * m_pos.Volume();
               totalLotSell += m_pos.Volume();
            }
         }
      }
      
      if(totalLotBuy > 0)
      {
         avgBuyPrice /= totalLotBuy;
         double tpPrice = avgBuyPrice + ТейкПрофит * symb.Point();
         
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            if(m_pos.SelectByIndex(i) && m_pos.Symbol() == Symbol() &&
               m_pos.Magic() == m_magic && m_pos.PositionType() == POSITION_TYPE_BUY)
            {
               if(MathAbs(m_pos.TakeProfit() - tpPrice) > symb.Point() * 2)
               {
                  m_trade.PositionModify(m_pos.Ticket(), m_pos.StopLoss(), tpPrice);
               }
            }
         }
      }
      
      if(totalLotSell > 0)
      {
         avgSellPrice /= totalLotSell;
         double tpPrice = avgSellPrice - ТейкПрофит * symb.Point();
         
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            if(m_pos.SelectByIndex(i) && m_pos.Symbol() == Symbol() &&
               m_pos.Magic() == m_magic && m_pos.PositionType() == POSITION_TYPE_SELL)
            {
               if(MathAbs(m_pos.TakeProfit() - tpPrice) > symb.Point() * 2)
               {
                  m_trade.PositionModify(m_pos.Ticket(), m_pos.StopLoss(), tpPrice);
               }
            }
         }
      }
   }

   void ManagePartialCloses(int buys, int sells)
   {
      if(buys > 1)
      {
         double avgBuyPrice = 0, totalLotBuy = 0;
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            if(m_pos.SelectByIndex(i) && m_pos.Magic() == m_magic &&
               m_pos.PositionType() == POSITION_TYPE_BUY)
            {
               avgBuyPrice += m_pos.PriceOpen() * m_pos.Volume();
               totalLotBuy += m_pos.Volume();
            }
         }
         
         if(totalLotBuy > 0)
         {
            avgBuyPrice /= totalLotBuy;
            double partialTpPrice = avgBuyPrice +
               (ТейкПрофит * ПрибыльЧастичного / 100.0) * symb.Point();
            
            for(int i = PositionsTotal() - 1; i >= 0; i--)
            {
               if(m_pos.SelectByIndex(i) && m_pos.Magic() == m_magic &&
                  m_pos.PositionType() == POSITION_TYPE_BUY)
               {
                  if(symb.Bid() >= partialTpPrice && m_pos.Profit() > 0)
                  {
                     m_trade.PositionClose(m_pos.Ticket());
                     break;
                  }
               }
            }
         }
      }
      
      if(sells > 1)
      {
         double avgSellPrice = 0, totalLotSell = 0;
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            if(m_pos.SelectByIndex(i) && m_pos.Magic() == m_magic &&
               m_pos.PositionType() == POSITION_TYPE_SELL)
            {
               avgSellPrice += m_pos.PriceOpen() * m_pos.Volume();
               totalLotSell += m_pos.Volume();
            }
         }
         
         if(totalLotSell > 0)
         {
            avgSellPrice /= totalLotSell;
            double partialTpPrice = avgSellPrice -
               (ТейкПрофит * ПроцентЧастичного / 100.0) * symb.Point();
            
            for(int i = PositionsTotal() - 1; i >= 0; i--)
            {
               if(m_pos.SelectByIndex(i) && m_pos.Magic() == m_magic &&
                  m_pos.PositionType() == POSITION_TYPE_SELL)
               {
                  if(symb.Ask() <= partialTpPrice && m_pos.Profit() > 0)
                  {
                     m_trade.PositionClose(m_pos.Ticket());
                     break;
                  }
               }
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
            if(m_pos.SelectByIndex(i) && m_pos.Magic() == m_magic &&
               m_pos.PositionType() == POSITION_TYPE_BUY)
            {
               double bePrice = m_pos.PriceOpen() + BreakevenBuffer * symb.Point();
               if(symb.Bid() >= bePrice && m_pos.StopLoss() < bePrice)
                  m_trade.PositionModify(m_pos.Ticket(), bePrice, m_pos.TakeProfit());
            }
         }
      }
      
      if(sells > 0)
      {
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            if(m_pos.SelectByIndex(i) && m_pos.Magic() == m_magic &&
               m_pos.PositionType() == POSITION_TYPE_SELL)
            {
               double bePrice = m_pos.PriceOpen() - BreakevenBuffer * symb.Point();
               if(symb.Ask() <= bePrice && (m_pos.StopLoss() == 0 || m_pos.StopLoss() > bePrice))
                  m_trade.PositionModify(m_pos.Ticket(), bePrice, m_pos.TakeProfit());
            }
         }
      }
   }
};

CGridStrategy Strat_Hilo;
CGridStrategy Strat_15;
CGridStrategy Strat_16;

CPositionInfo g_pos;

//+------------------------------------------------------------------+
//| ГЛОБАЛЬНОЕ ЗАКРЫТИЕ ВСЕХ ОРДЕРОВ                                |
//+------------------------------------------------------------------+
double GetGlobalProfit()
{
   double totalProfit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(g_pos.SelectByTicket(ticket))
      {
         if(g_pos.Symbol() == Symbol())
            totalProfit += g_pos.Profit();
      }
   }
   return totalProfit;
}

void CheckGlobalCloseConditions()
{
   double globalProfit = GetGlobalProfit();
   bool shouldClose = false;

   if(UseGlobalCloseByMoney)
   {
      if(globalProfit >= GlobalCloseMoney)
      {
         Print("ГЛОБАЛЬНОЕ ЗАКРЫТИЕ: Достигнута целевая прибыль $", GlobalCloseMoney,
               " Текущая прибыль: $", globalProfit);
         shouldClose = true;
      }
   }

   if(UseGlobalCloseByPercent && !shouldClose)
   {
      double bal = acc.Balance();
      double targetProfit = bal * GlobalClosePercent / 100.0;
      if(globalProfit >= targetProfit)
      {
         Print("ГЛОБАЛЬНОЕ ЗАКРЫТИЕ: Достигнут целевой процент ", GlobalClosePercent,
               "% Текущая прибыль: $", globalProfit);
         shouldClose = true;
      }
   }

   if(shouldClose)
   {
      CloseAllGlobalPositions();
   }
}

void CloseAllGlobalPositions()
{
   CTrade trade;
   trade.SetTypeFillingBySymbol(Symbol());

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(g_pos.SelectByTicket(ticket))
      {
         if(g_pos.Symbol() == Symbol())
         {
            trade.PositionClose(ticket);
            Print("Закрыта позиция: ", ticket, " Прибыль: ", g_pos.Profit());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| ФУНКЦИИ ТРЕНД-ФИЛЬТРА                                           |
//+------------------------------------------------------------------+
bool InitTrendFilters()
{
   if(!UseТрендФильтр)
      return true;

   g_ma_fast_handle = iMA(Symbol(), TrendTF, МА_Быстрая, 0, МА_Метод, МА_Цена);
   g_ma_mid_handle  = iMA(Symbol(), TrendTF, МА_Средняя, 0, МА_Метод, МА_Цена);
   g_ma_slow_handle = iMA(Symbol(), TrendTF, МА_Медленная, 0, МА_Метод, МА_Цена);

   if(g_ma_fast_handle == INVALID_HANDLE ||
      g_ma_mid_handle == INVALID_HANDLE ||
      g_ma_slow_handle == INVALID_HANDLE)
   {
      Print("ERROR: MA handles");
      return false;
   }

   return true;
}

double GetMA(int handle)
{
   if(handle == INVALID_HANDLE) return 0.0;
   double buf[1];
   if(CopyBuffer(handle, 0, 1, 1, buf) > 0)
      return buf[0];
   return 0.0;
}

double GetGridStepPoints()
{
   if(!UseATRGrid || g_atr_handle == INVALID_HANDLE)
      return ШагСетки;

   double atr_buf[1];
   if(CopyBuffer(g_atr_handle, 0, 0, 1, atr_buf) <= 0)
      return ШагСетки;

   double atr_price  = atr_buf[0];
   double atr_points = atr_price / symb.Point();

   double step_points = atr_points * ATR_Multiplier;
   if(step_points <= 0.0)
      step_points = ШагСетки;

   return step_points;
}

//+------------------------------------------------------------------+
//| GUI                                                              |
//+------------------------------------------------------------------+
void CreateLabel(const string name, int x, int y, const string text,
                 color clr, int fontsize, ENUM_BASE_CORNER corner = CORNER_RIGHT_UPPER)
{
   if(ObjectFind(0, name) == -1)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);

   ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontsize);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
}

void CreatePanelBackground(const string name, int x, int y, int w, int h,
                           color back, ENUM_BASE_CORNER corner = CORNER_RIGHT_UPPER)
{
   if(ObjectFind(0, name) == -1)
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);

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

int GetStaticPanelHeight()
{
   return CalculatePanelHeight(7, GUI_StepY, Panel_HeaderMargin, Panel_Padding);
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

   if(!symb.Name(Symbol()))
      return INIT_FAILED;
   symb.RefreshRates();

   g_global_trade.SetTypeFillingBySymbol(Symbol());

   if(!InitTrendFilters())
      return INIT_FAILED;

   if(UseATRGrid)
   {
      g_atr_handle = iATR(Symbol(), ATR_TF, ATR_Period);
      if(g_atr_handle == INVALID_HANDLE)
         return INIT_FAILED;
   }

   Strat_Hilo.Init(MagicHilo, МаксСделокHilo, ИспользоватьHilo,
                   Hilo_RSI_TF_Entry, Hilo_RSI_TF_Filter, Hilo_RSI_Period,
                   Hilo_RSI_BuyLevel, Hilo_RSI_SellLevel,
                   Hilo_WPR_TF_Entry, Hilo_WPR_TF_Filter, Hilo_WPR_Period,
                   Hilo_WPR_BuyLevel, Hilo_WPR_SellLevel,
                   Hilo_SignalType, КомментарийHilo,
                   Hilo_Mode);

   Strat_15.Init(Magic15, МаксСделок15, Использовать15,
                 S15_RSI_TF_Entry, S15_RSI_TF_Filter, S15_RSI_Period,
                 S15_RSI_BuyLevel, S15_RSI_SellLevel,
                 S15_WPR_TF_Entry, S15_WPR_TF_Filter, S15_WPR_Period,
                 S15_WPR_BuyLevel, S15_WPR_SellLevel,
                 Strat15_SignalType, Комментарий15,
                 S15_Mode);

   Strat_16.Init(Magic16, МаксСделок16, Использовать16,
                 S16_RSI_TF_Entry, S16_RSI_TF_Filter, S16_RSI_Period,
                 S16_RSI_BuyLevel, S16_RSI_SellLevel,
                 S16_WPR_TF_Entry, S16_WPR_TF_Filter, S16_WPR_Period,
                 S16_WPR_BuyLevel, S16_WPR_SellLevel,
                 Strat16_SignalType, Комментарий16,
                 S16_Mode);

   g_last_grid_bar_time = iTime(Symbol(), GridTF, 0);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, 0, -1);
   g_panel_created = false;
   Comment("");
   
   if(g_lock_active)
   {
      CloseLockPosition();
      Print("Лок закрыт при остановке советника");
   }
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!g_license_ok) return;
   if(!symb.RefreshRates()) return;
   if(ИспользоватьОстановку && CheckFloatingLoss()) return;

   UpdateTrendFlags();
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

//+------------------------------------------------------------------+
//| CheckFloatingLoss                                                |
//+------------------------------------------------------------------+
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
      if(g_panel_created)
      {
         ObjectsDeleteAll(0, 0, -1);
         g_panel_created = false;
      }
      Comment("");
      return;
   }

   Comment("");

   ENUM_BASE_CORNER corner = Panel_RightCorner ? CORNER_RIGHT_UPPER : CORNER_LEFT_UPPER;
   int baseX = GUI_X;
   int baseY = GUI_Y;
   int lineStep = GUI_StepY;

   string trendStatus = "---";
   if(UseТрендФильтр)
   {
      if(IsTrendBullish())      trendStatus = "↑BUY";
      else if(IsTrendBearish()) trendStatus = "↓SELL";
      else                      trendStatus = "→ФЛЭТ";
   }

   double globalProfit = GetGlobalProfit();
   string lockStatus = GetLockStatus();

   string head = "АлисА v7 | Bal: " + DoubleToString(acc.Balance(), 2) +
                 " Eq: " + DoubleToString(acc.Equity(), 2) +
                 " [" + trendStatus + "]";

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
   if(UseGlobalCloseByMoney)
      globalStatus += " / Цель: $" + DoubleToString(GlobalCloseMoney, 2);
   if(UseGlobalCloseByPercent)
      globalStatus += " / Цель: " + DoubleToString(GlobalClosePercent, 2) + "%";

   if(!g_panel_created)
   {
      int autoWidth  = GetStaticPanelWidth();
      int autoHeight = GetStaticPanelHeight();

      CreatePanelBackground("AlicePanelBG", baseX - 10, baseY - 10,
                            autoWidth, autoHeight, Panel_BackColor, corner);

      int y = baseY;

      CreateLabel("AlicePanel_Line0", baseX, y, head,
                  GUI_ColorMain, GUI_FontSize + 1, corner);
      y += lineStep + Panel_HeaderMargin;

      CreateLabel("AlicePanel_Line1", baseX, y, line1,
                  GUI_ColorHilo, GUI_FontSize, corner);
      y += lineStep;

      CreateLabel("AlicePanel_Line2", baseX, y, line2,
                  GUI_Color15, GUI_FontSize, corner);
      y += lineStep;

      CreateLabel("AlicePanel_Line3", baseX, y, line3,
                  GUI_Color16, GUI_FontSize, corner);
      y += lineStep;

      CreateLabel("AlicePanel_Global", baseX, y, globalStatus,
                  GUI_ColorGlobal, GUI_FontSize, corner);
      y += lineStep;
      
      CreateLabel("AlicePanel_Lock", baseX, y, lockStatus,
                  GUI_ColorLock, GUI_FontSize, corner);

      g_panel_created = true;
   }
   else
   {
      ObjectSetString(0, "AlicePanel_Line0", OBJPROP_TEXT, head);
      ObjectSetString(0, "AlicePanel_Line1", OBJPROP_TEXT, line1);
      ObjectSetString(0, "AlicePanel_Line2", OBJPROP_TEXT, line2);
      ObjectSetString(0, "AlicePanel_Line3", OBJPROP_TEXT, line3);
      ObjectSetString(0, "AlicePanel_Global", OBJPROP_TEXT, globalStatus);
      ObjectSetString(0, "AlicePanel_Lock", OBJPROP_TEXT, lockStatus);
   }
}

//+------------------------------------------------------------------+
//| Вспомогательные функции тренда                                   |
//+------------------------------------------------------------------+
bool IsTrendBullish()
{
   if(!UseТрендФильтр) return true;
   
   double fast = GetMA(g_ma_fast_handle);
   double mid  = GetMA(g_ma_mid_handle);
   double slow = GetMA(g_ma_slow_handle);
   
   return (fast > mid && mid > slow);
}

bool IsTrendBearish()
{
   if(!UseТрендФильтр) return true;
   
   double fast = GetMA(g_ma_fast_handle);
   double mid  = GetMA(g_ma_mid_handle);
   double slow = GetMA(g_ma_slow_handle);
   
   return (fast < mid && mid < slow);
}
//+------------------------------------------------------------------+
