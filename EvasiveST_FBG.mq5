//+------------------------------------------------------------------+
//|                                              EvasiveST_FBG.mq5   |
//|        Evasive SuperTrend  +  Ложный пробой по Герчику (MT5)     |
//|                                                                  |
//|  Объединённый индикатор:                                         |
//|   * Evasive SuperTrend — трендовая линия с механикой "ухода"     |
//|     от шумовой зоны (расширение полосы), цветные свечи,          |
//|     Bull/Bear стрелки на флипе, HTF-фильтр, адаптивный ATR.      |
//|   * Ложный пробой по Герчику — стрелка BUY/SELL на закрытом      |
//|     баре, когда тенью пробит ключевой уровень (N-баров или       |
//|     вчерашний D1), а тело закрылось обратно за уровнем.          |
//|   * Опция InpOnlyWithTrend — рисовать сигналы FBG только в       |
//|     направлении тренда ST.                                       |
//|   * Опция InpDrawCounterCross — если после входа по ST приходит  |
//|     встречный сигнал FBG, на этом баре рисуется крестик          |
//|     (Wingdings 251) — предупреждение об ослаблении тренда /      |
//|     возможном выходе.                                            |
//|                                                                  |
//|  Версия 2.01 — правки:                                           |
//|   1) Подавление ложного флип-сигнала на самом первом             |
//|      рассчитанном баре (нет надёжного предыдущего тренда).       |
//|   2) Корректный PLOT_EMPTY_VALUE=0 для DRAW_COLOR_CANDLES.       |
//|   3) InpAlertOnBarClose теперь распространяется и на сигналы     |
//|      Герчика — единый alertBarIdx для всех оповещений.           |
//|   4) Если рисуется встречный крест, стрелка FBG на этом же баре  |
//|      не дублируется (визуально не накладываются).                |
//|   5) HTF ATR теперь сидится классическим SMA на первых p барах   |
//|      (как у Уайлдера в основном блоке) — стабильнее на истории.  |
//|   6) Введена PipSize() с авто-коррекцией для 3/5-знаков, чтобы   |
//|      InpFBGOffsetPts работал в "пунктах трейдера", а не в        |
//|      _Point=0.00001 (пятые знаки).                               |
//|                                                                  |
//|  Версия 2.02 — расширение HTF-фильтра:                           |
//|   7) HTF-фильтр теперь применяется и к сигналам Герчика, и к     |
//|      встречному кресту (раньше учитывался только в стрелках ST). |
//|      Стрелка FBG требует совпадения LTF и HTF трендов.           |
//|      Крест рисуется при противоречии с LTF ИЛИ с HTF.            |
//|   8) Опция InpHtfFailOpen — поведение при недоступном HTF        |
//|      (htf==0): true — пропускать сигналы, false — блокировать.   |
//|   9) Визуальный бейдж в углу графика со статусом HTF (Up/Dn/--). |
//|                                                                  |
//|  Версия 2.03 — визуализация, лог, производительность:            |
//|  10) Линии уровней Герчика (HH/LL) на основном графике —         |
//|      InpDrawFBGLevels: видно, относительно чего был «ложный      |
//|      пробой».                                                    |
//|  11) Линия HTF SuperTrend на основном графике (цветная) —        |
//|      InpDrawHtfST: уровень старшего ТФ под глазами.              |
//|  12) CSV-лог сигналов: ST-флип, FBG buy/sell, встречный крест.   |
//|      InpLogToCSV + InpLogFileName, поля: time;symbol;period;     |
//|      type;side;price;level;ltf;htf;evasive;atr.                  |
//|  13) Расширенный HTF-бейдж (InpHtfBadgeDetails): дополнительная  |
//|      строка с LTF-трендом и флагом evasive.                      |
//|  14) Производительность: инкрементальный курсор для HTF-поиска   |
//|      (амортизированно O(1) на бар) и скользящее окно для         |
//|      Efficiency Ratio в адаптивном ATR (вместо O(n) на бар).    |
//|  15) Косметика: короткий лейбл таймфрейма в алертах (M15, H1)    |
//|      вместо PERIOD_M15.                                          |
//+------------------------------------------------------------------+
#property copyright "Devin"
#property version   "2.03"
#property description "СуперТренд+Герчик: HTF-фильтр, уровни FBG, линия HTF ST, CSV-лог"
#property indicator_chart_window
#property indicator_buffers 22
#property indicator_plots   11

//--- Plot 0: основная линия СуперТренда (сплошная)
#property indicator_label1   "СуперТренд"
#property indicator_type1    DRAW_COLOR_LINE
#property indicator_color1   clrLimeGreen,clrTomato
#property indicator_style1   STYLE_SOLID
#property indicator_width1   2

//--- Plot 1: линия СуперТренда в фазе ухода (пунктир)
#property indicator_label2   "СуперТренд (уход)"
#property indicator_type2    DRAW_COLOR_LINE
#property indicator_color2   clrLimeGreen,clrTomato
#property indicator_style2   STYLE_DOT
#property indicator_width2   2

//--- Plot 2: стрелка бычьего входа
#property indicator_label3   "Бычий вход"
#property indicator_type3    DRAW_ARROW
#property indicator_color3   clrLime
#property indicator_width3   3

//--- Plot 3: стрелка медвежьего входа
#property indicator_label4   "Медвежий вход"
#property indicator_type4    DRAW_ARROW
#property indicator_color4   clrTomato
#property indicator_width4   3

//--- Plot 4: свечи, окрашенные по тренду
#property indicator_label5   "Свечи по тренду"
#property indicator_type5    DRAW_COLOR_CANDLES
#property indicator_color5   clrLimeGreen,clrTomato

//--- Plot 5: сигнал Герчика на покупку
#property indicator_label6   "Герчик Покупка"
#property indicator_type6    DRAW_ARROW
#property indicator_color6   clrDeepSkyBlue
#property indicator_width6   2

//--- Plot 6: сигнал Герчика на продажу
#property indicator_label7   "Герчик Продажа"
#property indicator_type7    DRAW_ARROW
#property indicator_color7   clrMagenta
#property indicator_width7   2

//--- Plot 7: крест на встречном сигнале Герчика
#property indicator_label8   "Герчик Встречный"
#property indicator_type8    DRAW_ARROW
#property indicator_color8   clrRed
#property indicator_width8   4

//--- Plot 8: линия HTF SuperTrend на основном графике (цветная)
#property indicator_label9   "HTF СуперТренд"
#property indicator_type9    DRAW_COLOR_LINE
#property indicator_color9   clrSeaGreen,clrFireBrick
#property indicator_style9   STYLE_DASHDOT
#property indicator_width9   2

//--- Plot 9: верхний уровень Герчика (сопротивление, HH)
#property indicator_label10  "Герчик HH"
#property indicator_type10   DRAW_LINE
#property indicator_color10  clrGoldenrod
#property indicator_style10  STYLE_DOT
#property indicator_width10  1

//--- Plot 10: нижний уровень Герчика (поддержка, LL)
#property indicator_label11  "Герчик LL"
#property indicator_type11   DRAW_LINE
#property indicator_color11  clrSteelBlue
#property indicator_style11  STYLE_DOT
#property indicator_width11  1

//================== Перечисления =====================================
enum ENUM_FBG_LEVEL_MODE
  {
   FBG_LEVEL_NBARS = 0,  // Экстремум за N баров
   FBG_LEVEL_DAILY = 1   // Вчерашний High/Low (D1)
  };

//================== Входные параметры =============================
input group "=== Настройки СуперТренда ==="
input int                InpAtrLength      = 10;         // Длина ATR
input double             InpBaseMultiplier = 3.0;        // Базовый множитель

input group "=== Уход от шумовой зоны ==="
input double             InpNoiseThreshold = 1.0;        // Порог шума (xATR) — ширина опасной зоны
input double             InpExpansionAlpha = 0.5;        // Расширение (xATR) — сила ухода
input bool               InpEvasionPersist = true;       // Сохранять смещение ухода на следующий бар

input group "=== Адаптивный ATR (Кауфман) ==="
input bool               InpAdaptive       = false;      // Адаптивный ATR вместо Уайлдера
input int                InpAdaptiveMin    = 5;          // Быстрый эфф. период
input int                InpAdaptiveMax    = 30;         // Медленный эфф. период
input int                InpEfficiencyLen  = 10;         // Длина Efficiency Ratio

input group "=== Подтверждение по старшему ТФ ==="
input bool               InpUseHTF         = false;      // Фильтр сигналов по старшему ТФ
input ENUM_TIMEFRAMES    InpHTF            = PERIOD_H1;  // Старший таймфрейм
input int                InpHtfAtrPeriod   = 10;         // Период ATR на старшем ТФ
input double             InpHtfMultiplier  = 3.0;        // Множитель ATR на старшем ТФ
input bool               InpHtfFailOpen    = true;       // При недоступном HTF (htf=0) пропускать сигналы
input bool               InpHtfShowBadge   = true;       // Показывать бейдж со статусом HTF в углу
input ENUM_BASE_CORNER   InpHtfBadgeCorner = CORNER_RIGHT_UPPER; // Угол для бейджа

input group "=== Визуализация СуперТренда ==="
input bool               InpShowSignals    = true;       // Рисовать стрелки быч./медв. входа
input bool               InpColorCandles   = true;       // Красить свечи по тренду
input int                InpArrowBuyCode   = 233;        // Код Wingdings для бычьей стрелки
input int                InpArrowSellCode  = 234;        // Код Wingdings для медвежьей стрелки

input group "=== Ложный пробой по Герчику ==="
input bool               InpFBGEnabled     = true;       // Включить сигналы Герчика
input ENUM_FBG_LEVEL_MODE InpFBGLevelMode  = FBG_LEVEL_NBARS; // Источник уровня
input int                InpFBGLookback    = 20;         // Длина окна N (для режима N баров)
input double             InpFBGMinTailATR  = 0.15;       // Мин. размер хвоста пробоя (xATR; 0 — выкл.)
input double             InpFBGMaxBodyATR  = 1.50;       // Макс. тело бара (xATR; 0 — выкл.)
input int                InpFBGArrowBuy    = 241;        // Код Wingdings для стрелки «Герчик Покупка»
input int                InpFBGArrowSell   = 242;        // Код Wingdings для стрелки «Герчик Продажа»
input int                InpFBGOffsetPts   = 10;         // Отступ стрелки от бара (в пунктах трейдера)

input group "=== Фильтр тренда / Встречный крест ==="
input bool               InpOnlyWithTrend  = true;       // Сигналы Герчика только по тренду СуперТренда
input bool               InpDrawCounterCross = true;     // Рисовать крест на встречном сигнале Герчика
input int                InpCounterCrossCode = 251;      // Код Wingdings для креста
input bool               InpAlertOnFBG     = true;       // Оповещение по сигналам Герчика
input bool               InpAlertOnCounter = true;       // Оповещение по встречному кресту

input group "=== Оповещения ==="
input bool               InpAlertOnBarClose= true;       // Оповещать только на закрытии бара
input bool               InpAlertPopup     = true;       // Popup-оповещение
input bool               InpAlertSound     = true;       // Звуковое оповещение
input string             InpSoundFile      = "alert.wav";// Звуковой файл
input bool               InpAlertPush      = false;      // Push-уведомление
input bool               InpAlertEmail     = false;      // E-mail оповещение

input group "=== v2.03: визуализация уровней и HTF ==="
input bool               InpDrawFBGLevels  = true;       // Рисовать линии HH/LL Герчика
input bool               InpDrawHtfST      = false;      // Рисовать линию HTF SuperTrend на основном графике
input bool               InpHtfBadgeDetails= false;      // Расширенный бейдж: добавить LTF и флаг ухода

input group "=== v2.03: журнал сигналов (CSV) ==="
input bool               InpLogToCSV       = false;      // Писать сигналы в CSV-файл (MQL5/Files)
input string             InpLogFileName    = "EvasiveST_FBG_signals.csv"; // Имя CSV-файла
input bool               InpLogSTFlip      = true;       // Логировать флипы СуперТренда
input bool               InpLogFBG         = true;       // Логировать сигналы Герчика (BUY/SELL)
input bool               InpLogCounter     = true;       // Логировать встречные кресты

//================== Буферы индикатора ============================
double BufSTSolid[];       // 0
double BufSTSolidCol[];    // 1
double BufSTEvasive[];     // 2
double BufSTEvasiveCol[];  // 3
double BufSTBull[];        // 4
double BufSTBear[];        // 5
double BufCandleO[];       // 6
double BufCandleH[];       // 7
double BufCandleL[];       // 8
double BufCandleC[];       // 9
double BufCandleCol[];     // 10
double BufFBGBuy[];        // 11
double BufFBGSell[];       // 12
double BufFBGCross[];      // 13
double BufHtfST[];         // 14 (v2.03) — линия HTF ST
double BufHtfSTCol[];      // 15 (v2.03) — цветовой индекс HTF ST
double BufFBGHigh[];       // 16 (v2.03) — линия HH (сопротивление)
double BufFBGLow[];        // 17 (v2.03) — линия LL (поддержка)
double BufTrend[];         // 18 calc
double BufFU[];            // 19 calc - final upper
double BufFL[];            // 20 calc - final lower
double BufEvasive[];       // 21 calc - 1 if evasive mode active

//================== Состояние индикатора =========================
double      g_atr[];
//--- (v2.03) скользящие суммы для Efficiency Ratio (адаптивный ATR)
double      g_erVol[];      // суммарная |Δclose| в окне
double      g_erChange[];   // |close[i]-close[i-n]|
struct HTFTrendBar { datetime time; int trend; double st; int col; };
HTFTrendBar g_htf[];
datetime    g_htfLastUpdate = 0;
//--- (v2.03) инкрементальный курсор для HTFTrendAt по монотонному времени
int         g_htfCursor = 0;
datetime    g_lastSTAlertTime  = 0;
datetime    g_lastFBGAlertTime = 0;
datetime    g_lastCrossAlertTime = 0;
//--- (v2.03) кэш handle лог-файла (файл переоткрывается реже)
int         g_logHandle = INVALID_HANDLE;
string      g_logFileName = "";

//--- имя графического объекта-бейджа HTF
const string HTF_BADGE_NAME = "EvST_FBG_HTF_Badge";

//+------------------------------------------------------------------+
//| Размер «пункта трейдера» с авто-коррекцией для 3/5-знаков        |
//+------------------------------------------------------------------+
double PipSize()
  {
   int d = (int)_Digits;
   if(d == 3 || d == 5) return _Point * 10.0;
   return _Point;
  }

//+------------------------------------------------------------------+
//| (v2.03 #15) Короткий человекочитаемый лейбл таймфрейма           |
//|   Заменяет EnumToString(PERIOD_M15) -> "M15".                    |
//+------------------------------------------------------------------+
string TfLabel(const ENUM_TIMEFRAMES tf)
  {
   string s = EnumToString(tf);
   int p = StringFind(s, "PERIOD_");
   if(p == 0) s = StringSubstr(s, 7);
   return s;
  }

//+------------------------------------------------------------------+
//| (v2.03 #12) Открытие/переоткрытие CSV-журнала                    |
//|   Формат: time;symbol;period;type;side;price;level;ltf;htf;      |
//|           evasive;atr                                            |
//+------------------------------------------------------------------+
void OpenLogFile()
  {
   if(!InpLogToCSV) { CloseLogFile(); return; }
   if(g_logHandle != INVALID_HANDLE && g_logFileName == InpLogFileName) return;
   CloseLogFile();
   bool fresh = !FileIsExist(InpLogFileName);
   g_logHandle = FileOpen(InpLogFileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ';');
   if(g_logHandle == INVALID_HANDLE)
     {
      PrintFormat("[EvasiveST_FBG] Не удалось открыть лог '%s', err=%d",
                  InpLogFileName, GetLastError());
      return;
     }
   FileSeek(g_logHandle, 0, SEEK_END);
   if(fresh)
     {
      FileWrite(g_logHandle,
                "time","symbol","period","type","side",
                "price","level","ltf","htf","evasive","atr");
     }
   g_logFileName = InpLogFileName;
  }

void CloseLogFile()
  {
   if(g_logHandle != INVALID_HANDLE)
     {
      FileClose(g_logHandle);
      g_logHandle = INVALID_HANDLE;
     }
   g_logFileName = "";
  }

//+------------------------------------------------------------------+
//| (v2.03 #12) Записать одну строку события в CSV                   |
//+------------------------------------------------------------------+
void LogSignal(const datetime t, const string type, const string side,
               const double price, const double level,
               const int ltf, const int htf, const bool evasive,
               const double atr)
  {
   if(!InpLogToCSV) return;
   if(g_logHandle == INVALID_HANDLE) OpenLogFile();
   if(g_logHandle == INVALID_HANDLE) return;
   FileWrite(g_logHandle,
             TimeToString(t, TIME_DATE|TIME_MINUTES|TIME_SECONDS),
             _Symbol,
             TfLabel((ENUM_TIMEFRAMES)_Period),
             type, side,
             DoubleToString(price, _Digits),
             (level > 0.0) ? DoubleToString(level, _Digits) : "",
             ltf, htf, (int)evasive,
             DoubleToString(atr, _Digits));
   FileFlush(g_logHandle);
  }

//+------------------------------------------------------------------+
//| (правка #7-#8) Проверка разрешения сигнала по HTF                |
//|   side = +1 для бычьего, -1 для медвежьего                       |
//|   Возвращает true, если HTF не запрещает сигнал в эту сторону.   |
//+------------------------------------------------------------------+
bool HTFAllows(const datetime t, const int side)
  {
   if(!InpUseHTF) return true;
   int htf = HTFTrendAt(t);
   if(htf == 0) return InpHtfFailOpen; // данных нет — fail-open/closed по флагу
   return (side == 1) ? (htf >= 0) : (htf <= 0);
  }

//+------------------------------------------------------------------+
//| (правка #9 + v2.03 #13) Создать/обновить бейдж со статусом HTF   |
//+------------------------------------------------------------------+
void UpdateHTFBadge(const datetime barTime, const int ltfTrend, const bool evasive)
  {
   if(!InpUseHTF || !InpHtfShowBadge)
     {
      if(ObjectFind(0, HTF_BADGE_NAME) >= 0)
         ObjectDelete(0, HTF_BADGE_NAME);
      return;
     }

   int htf = HTFTrendAt(barTime);
   string txt;
   color  clr;
   if(htf > 0)      { txt = "HTF " + TfLabel(InpHTF) + ": Up";  clr = clrLimeGreen; }
   else if(htf < 0) { txt = "HTF " + TfLabel(InpHTF) + ": Dn";  clr = clrTomato;    }
   else             { txt = "HTF " + TfLabel(InpHTF) + ": --";  clr = clrSilver;    }

   //--- (v2.03 #13) при включённой детализации добавляем LTF + флаг ухода
   if(InpHtfBadgeDetails)
     {
      string ltfTxt = (ltfTrend > 0) ? "Up" : (ltfTrend < 0) ? "Dn" : "--";
      txt += "  |  LTF " + TfLabel((ENUM_TIMEFRAMES)_Period) + ": " + ltfTxt;
      if(evasive) txt += " (evasive)";
     }

   if(ObjectFind(0, HTF_BADGE_NAME) < 0)
     {
      if(!ObjectCreate(0, HTF_BADGE_NAME, OBJ_LABEL, 0, 0, 0)) return;
      ObjectSetInteger(0, HTF_BADGE_NAME, OBJPROP_CORNER,    InpHtfBadgeCorner);
      ObjectSetInteger(0, HTF_BADGE_NAME, OBJPROP_XDISTANCE, 12);
      ObjectSetInteger(0, HTF_BADGE_NAME, OBJPROP_YDISTANCE, 20);
      ObjectSetInteger(0, HTF_BADGE_NAME, OBJPROP_FONTSIZE,  10);
      ObjectSetString (0, HTF_BADGE_NAME, OBJPROP_FONT,      "Arial Bold");
      ObjectSetInteger(0, HTF_BADGE_NAME, OBJPROP_HIDDEN,    true);
      ObjectSetInteger(0, HTF_BADGE_NAME, OBJPROP_BACK,      false);
      ObjectSetInteger(0, HTF_BADGE_NAME, OBJPROP_SELECTABLE,false);
      // Привязка по углу: для правого угла текст выравнивается вправо
      bool rightCorner = (InpHtfBadgeCorner == CORNER_RIGHT_UPPER ||
                          InpHtfBadgeCorner == CORNER_RIGHT_LOWER);
      ObjectSetInteger(0, HTF_BADGE_NAME, OBJPROP_ANCHOR,
                       rightCorner ? ANCHOR_RIGHT_UPPER : ANCHOR_LEFT_UPPER);
     }
   ObjectSetString (0, HTF_BADGE_NAME, OBJPROP_TEXT,  txt);
   ObjectSetInteger(0, HTF_BADGE_NAME, OBJPROP_COLOR, clr);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   SetIndexBuffer(0,  BufSTSolid,      INDICATOR_DATA);
   SetIndexBuffer(1,  BufSTSolidCol,   INDICATOR_COLOR_INDEX);
   SetIndexBuffer(2,  BufSTEvasive,    INDICATOR_DATA);
   SetIndexBuffer(3,  BufSTEvasiveCol, INDICATOR_COLOR_INDEX);
   SetIndexBuffer(4,  BufSTBull,       INDICATOR_DATA);
   SetIndexBuffer(5,  BufSTBear,       INDICATOR_DATA);
   SetIndexBuffer(6,  BufCandleO,      INDICATOR_DATA);
   SetIndexBuffer(7,  BufCandleH,      INDICATOR_DATA);
   SetIndexBuffer(8,  BufCandleL,      INDICATOR_DATA);
   SetIndexBuffer(9,  BufCandleC,      INDICATOR_DATA);
   SetIndexBuffer(10, BufCandleCol,    INDICATOR_COLOR_INDEX);
   SetIndexBuffer(11, BufFBGBuy,       INDICATOR_DATA);
   SetIndexBuffer(12, BufFBGSell,      INDICATOR_DATA);
   SetIndexBuffer(13, BufFBGCross,     INDICATOR_DATA);
   //--- (v2.03) HTF ST line + цветовой индекс
   SetIndexBuffer(14, BufHtfST,        INDICATOR_DATA);
   SetIndexBuffer(15, BufHtfSTCol,     INDICATOR_COLOR_INDEX);
   //--- (v2.03) уровни Герчика
   SetIndexBuffer(16, BufFBGHigh,      INDICATOR_DATA);
   SetIndexBuffer(17, BufFBGLow,       INDICATOR_DATA);
   //--- служебные расчётные буферы
   SetIndexBuffer(18, BufTrend,        INDICATOR_CALCULATIONS);
   SetIndexBuffer(19, BufFU,           INDICATOR_CALCULATIONS);
   SetIndexBuffer(20, BufFL,           INDICATOR_CALCULATIONS);
   SetIndexBuffer(21, BufEvasive,      INDICATOR_CALCULATIONS);

   PlotIndexSetInteger(2, PLOT_ARROW, InpArrowBuyCode);
   PlotIndexSetInteger(3, PLOT_ARROW, InpArrowSellCode);
   PlotIndexSetInteger(5, PLOT_ARROW, InpFBGArrowBuy);
   PlotIndexSetInteger(6, PLOT_ARROW, InpFBGArrowSell);
   PlotIndexSetInteger(7, PLOT_ARROW, InpCounterCrossCode);

   //--- (правка #2) для линий/стрелок «пусто» = EMPTY_VALUE,
   //    для DRAW_COLOR_CANDLES (plot 4) — 0.0
   PlotIndexSetDouble(0,  PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1,  PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(2,  PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(3,  PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(4,  PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(5,  PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(6,  PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(7,  PLOT_EMPTY_VALUE, EMPTY_VALUE);
   //--- (v2.03) HTF ST line + уровни Герчика
   PlotIndexSetDouble(8,  PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(9,  PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(10, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   if(!InpColorCandles)
      PlotIndexSetInteger(4, PLOT_DRAW_TYPE, DRAW_NONE);
   if(!InpShowSignals)
     {
      PlotIndexSetInteger(2, PLOT_DRAW_TYPE, DRAW_NONE);
      PlotIndexSetInteger(3, PLOT_DRAW_TYPE, DRAW_NONE);
     }
   if(!InpFBGEnabled)
     {
      PlotIndexSetInteger(5,  PLOT_DRAW_TYPE, DRAW_NONE);
      PlotIndexSetInteger(6,  PLOT_DRAW_TYPE, DRAW_NONE);
      PlotIndexSetInteger(7,  PLOT_DRAW_TYPE, DRAW_NONE);
      PlotIndexSetInteger(9,  PLOT_DRAW_TYPE, DRAW_NONE);
      PlotIndexSetInteger(10, PLOT_DRAW_TYPE, DRAW_NONE);
     }
   else if(!InpDrawCounterCross)
      PlotIndexSetInteger(7, PLOT_DRAW_TYPE, DRAW_NONE);

   //--- (v2.03 #10) уровни Герчика отключаем явным флагом
   if(!InpDrawFBGLevels)
     {
      PlotIndexSetInteger(9,  PLOT_DRAW_TYPE, DRAW_NONE);
      PlotIndexSetInteger(10, PLOT_DRAW_TYPE, DRAW_NONE);
     }
   //--- (v2.03 #11) HTF ST линия — зависит от InpUseHTF и InpDrawHtfST
   if(!InpUseHTF || !InpDrawHtfST)
      PlotIndexSetInteger(8, PLOT_DRAW_TYPE, DRAW_NONE);

   IndicatorSetString(INDICATOR_SHORTNAME,
      StringFormat("СуперТренд+Герчик (ATR=%d, x%.2f, шум=%.2f, расш=%.2f%s%s%s)",
         InpAtrLength, InpBaseMultiplier, InpNoiseThreshold, InpExpansionAlpha,
         InpAdaptive       ? ", адаптив" : "",
         InpUseHTF         ? StringFormat(", стТФ=%s", TfLabel(InpHTF)) : "",
         InpFBGEnabled     ? (InpOnlyWithTrend ? ", Герчик-по тренду" : ", Герчик-все") : ""));

   g_htfLastUpdate     = 0;
   g_htfCursor         = 0;
   g_lastSTAlertTime   = 0;
   g_lastFBGAlertTime  = 0;
   g_lastCrossAlertTime= 0;

   //--- (v2.03 #12) открываем CSV-журнал, если включён
   OpenLogFile();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   ArrayFree(g_atr);
   ArrayFree(g_htf);
   ArrayFree(g_erVol);
   ArrayFree(g_erChange);
   CloseLogFile();
   if(ObjectFind(0, HTF_BADGE_NAME) >= 0)
      ObjectDelete(0, HTF_BADGE_NAME);
  }

//================== Вспомогательные функции =======================
double TrueRange(const double h, const double l, const double pc)
  {
   return MathMax(h - l, MathMax(MathAbs(h - pc), MathAbs(l - pc)));
  }

double EfficiencyRatio(const double &close[], const int i, const int n)
  {
   if(i < n) return 0.0;
   double change = MathAbs(close[i] - close[i-n]);
   double vol = 0.0;
   for(int k=i-n+1; k<=i; ++k)
      vol += MathAbs(close[k] - close[k-1]);
   return (vol > 0.0) ? change / vol : 0.0;
  }

//+------------------------------------------------------------------+
//| (v2.03 #14) Скользящие окна для Efficiency Ratio                 |
//|   g_erVol[i]    — сумма |Δclose| за последние n шагов до i       |
//|   g_erChange[i] — |close[i] - close[i-n]|                        |
//|   Поддерживаются инкрементально: O(1) на бар.                    |
//+------------------------------------------------------------------+
void EnsureERWindow(const int rates_total)
  {
   if(ArraySize(g_erVol)    != rates_total) ArrayResize(g_erVol,    rates_total);
   if(ArraySize(g_erChange) != rates_total) ArrayResize(g_erChange, rates_total);
  }

double EfficiencyRatioFast(const double &close[], const int i, const int n)
  {
   if(i < n) return 0.0;
   //--- скользящая сумма |Δclose|: prev + новый шаг − выпавший шаг
   //    шаг k = |close[k] - close[k-1]|, окно k ∈ (i-n, i]
   double vol;
   if(i == n)
     {
      double s = 0.0;
      for(int k=1; k<=n; ++k) s += MathAbs(close[k] - close[k-1]);
      vol = s;
     }
   else
     {
      double dropped = MathAbs(close[i-n] - close[i-n-1]);
      double added   = MathAbs(close[i]   - close[i-1]);
      vol = g_erVol[i-1] + added - dropped;
      if(vol < 0.0) vol = 0.0;
     }
   g_erVol[i] = vol;
   double change = MathAbs(close[i] - close[i-n]);
   g_erChange[i] = change;
   return (vol > 0.0) ? change / vol : 0.0;
  }

//+------------------------------------------------------------------+
//| Построение/обновление кэша ATR (Уайлдер или Кауфман)             |
//+------------------------------------------------------------------+
void ComputeATR(const int rates_total,
                const double &high[], const double &low[], const double &close[])
  {
   if(ArraySize(g_atr) != rates_total) ArrayResize(g_atr, rates_total);
   if(rates_total <= 1) { ArrayInitialize(g_atr, 0.0); return; }
   g_atr[0] = 0.0;

   if(InpAdaptive)
     {
      EnsureERWindow(rates_total);
      double fast = 2.0 / (InpAdaptiveMin + 1.0);
      double slow = 2.0 / (InpAdaptiveMax + 1.0);
      double prev = TrueRange(high[1], low[1], close[0]);
      g_atr[1] = prev;
      for(int i=2; i<rates_total; ++i)
        {
         double tr = TrueRange(high[i], low[i], close[i-1]);
         double er = EfficiencyRatioFast(close, i, InpEfficiencyLen);
         double sc = MathPow(er * (fast - slow) + slow, 2.0);
         prev = prev + sc * (tr - prev);
         g_atr[i] = prev;
        }
     }
   else
     {
      int p = (InpAtrLength < 1) ? 1 : InpAtrLength;
      double sum = 0.0;
      int seedEnd = MathMin(rates_total-1, p);
      for(int i=1; i<=seedEnd; ++i)
        {
         sum += TrueRange(high[i], low[i], close[i-1]);
         g_atr[i] = sum / i;
        }
      for(int i=p+1; i<rates_total; ++i)
        {
         double tr = TrueRange(high[i], low[i], close[i-1]);
         g_atr[i] = (g_atr[i-1]*(p-1) + tr) / p;
        }
     }
  }

//+------------------------------------------------------------------+
//| Пересчёт кэша тренда на старшем ТФ (обычный SuperTrend)          |
//| (правка #5) — корректный SMA-сид ATR на первых p барах           |
//+------------------------------------------------------------------+
void RebuildHTFTrend()
  {
   if(!InpUseHTF) { ArrayResize(g_htf, 0); return; }
   datetime lastHTFBar = (datetime)SeriesInfoInteger(_Symbol, InpHTF, SERIES_LASTBAR_DATE);
   if(lastHTFBar == g_htfLastUpdate && ArraySize(g_htf) > 0) return;

   int bars = Bars(_Symbol, InpHTF);
   if(bars < 5) return;
   int want = MathMin(bars, 5000);
   MqlRates r[];
   int copied = CopyRates(_Symbol, InpHTF, 0, want, r);
   if(copied < 5) return;

   ArrayResize(g_htf, copied);
   double atr=0.0, prevUpper=0.0, prevLower=0.0;
   double sumTr = 0.0;
   int    p = (InpHtfAtrPeriod < 1) ? 1 : InpHtfAtrPeriod;
   int trend = 1;
   g_htf[0].time = r[0].time; g_htf[0].trend = trend;
   g_htf[0].st   = 0.0;       g_htf[0].col   = 0;

   for(int i=1; i<copied; ++i)
     {
      g_htf[i].time = r[i].time;
      double tr = TrueRange(r[i].high, r[i].low, r[i-1].close);

      if(i <= p)
        {
         sumTr += tr;
         atr   = sumTr / i;          // SMA-сид
        }
      else
        {
         atr = (atr*(p-1.0) + tr)/p; // Уайлдер
        }

      double hl2 = (r[i].high + r[i].low) * 0.5;
      double bu  = hl2 + InpHtfMultiplier*atr;
      double bl  = hl2 - InpHtfMultiplier*atr;
      double fu  = (bu < prevUpper || r[i-1].close > prevUpper) ? bu : prevUpper;
      double fl  = (bl > prevLower || r[i-1].close < prevLower) ? bl : prevLower;

      if(trend == 1)  trend = (r[i].close < fl) ? -1 :  1;
      else            trend = (r[i].close > fu) ?  1 : -1;

      //--- (v2.03 #11) сохраняем уровень линии ST на HTF и цветовой индекс
      g_htf[i].trend = trend;
      g_htf[i].st    = (trend == 1) ? fl : fu;
      g_htf[i].col   = (trend == 1) ? 0  : 1;
      prevUpper = fu; prevLower = fl;
     }
   g_htfLastUpdate = lastHTFBar;
   //--- (v2.03 #14) сбрасываем курсор поиска: массив пересобран
   g_htfCursor = 0;
  }

int HTFTrendAt(const datetime t)
  {
   int n = ArraySize(g_htf);
   if(n == 0) return 0;
   //--- (v2.03 #14) Инкрементальный курсор: время в OnCalculate монотонно
   //    растёт, поэтому в среднем курсор сдвигается на 1 шаг вперёд за раз.
   //    Проваливаемся в бинарный поиск только если курсор оторван (history
   //    refresh, прыжок назад).
   int idx = g_htfCursor;
   if(idx >= n) idx = n - 1;
   if(idx < 0)  idx = 0;
   if(g_htf[idx].time <= t)
     {
      while(idx + 1 < n && g_htf[idx + 1].time <= t) ++idx;
      g_htfCursor = idx;
      return g_htf[idx].trend;
     }
   //--- курсор впереди искомого времени → линейный откат недорогой,
   //    но защищаемся от больших скачков назад классическим поиском
   if(idx > 0 && g_htf[idx - 1].time <= t)
     {
      g_htfCursor = idx - 1;
      return g_htf[idx - 1].trend;
     }
   //--- редкая ветка: фолбек на бинарный поиск
   int lo=0, hi=n-1, ans=-1;
   while(lo <= hi)
     {
      int mid = (lo+hi) >> 1;
      if(g_htf[mid].time <= t) { ans = mid; lo = mid+1; }
      else hi = mid-1;
     }
   if(ans < 0) return 0;
   g_htfCursor = ans;
   return g_htf[ans].trend;
  }

//+------------------------------------------------------------------+
//| (v2.03 #11) Получить уровень и цвет HTF SuperTrend на время t    |
//|   Возвращает false, если данных нет.                             |
//+------------------------------------------------------------------+
bool HTFLineAt(const datetime t, double &outSt, int &outCol)
  {
   int n = ArraySize(g_htf);
   if(n == 0) return false;
   //--- сначала найдём индекс через тот же курсор, что и HTFTrendAt
   HTFTrendAt(t);
   int idx = g_htfCursor;
   if(idx < 0 || idx >= n) return false;
   if(g_htf[idx].time > t) return false; // совсем нет покрытия
   if(g_htf[idx].st <= 0.0) return false; // первый бар-сид
   outSt  = g_htf[idx].st;
   outCol = g_htf[idx].col;
   return true;
  }

//+------------------------------------------------------------------+
//| Отрисовка значения СуперТренда в нужный буфер                    |
//+------------------------------------------------------------------+
void PlotST(const int i, const double v, const int trend, const bool evasive)
  {
   int col = (trend == 1) ? 0 : 1;

   BufSTSolid[i]      = EMPTY_VALUE;
   BufSTEvasive[i]    = EMPTY_VALUE;
   BufSTSolidCol[i]   = 0;
   BufSTEvasiveCol[i] = 0;

   if(evasive) { BufSTEvasive[i] = v; BufSTEvasiveCol[i] = col; }
   else        { BufSTSolid[i]   = v; BufSTSolidCol[i]   = col; }

   if(i > 0)
     {
      bool prevSolid   = (BufSTSolid[i-1]   != EMPTY_VALUE);
      bool prevEvasive = (BufSTEvasive[i-1] != EMPTY_VALUE);
      if(evasive && prevSolid)        { BufSTSolid[i]   = v; BufSTSolidCol[i]   = col; }
      else if(!evasive && prevEvasive){ BufSTEvasive[i] = v; BufSTEvasiveCol[i] = col; }
     }
  }

//+------------------------------------------------------------------+
//| Уровни Герчика (экстремум за N баров или вчерашний D1)           |
//+------------------------------------------------------------------+
bool GetFBGLevels(const int       i,
                  const datetime &time[],
                  const double   &high[],
                  const double   &low[],
                  double         &outHigh,
                  double         &outLow)
  {
   outHigh = 0.0; outLow = 0.0;

   if(InpFBGLevelMode == FBG_LEVEL_NBARS)
     {
      if(i - InpFBGLookback < 0) return false;
      double hh = high[i - 1];
      double ll = low[i - 1];
      for(int k=2; k<=InpFBGLookback; ++k)
        {
         int idx = i - k;
         if(idx < 0) return false;
         if(high[idx] > hh) hh = high[idx];
         if(low[idx]  < ll) ll = low[idx];
        }
      outHigh = hh; outLow = ll;
      return true;
     }

   // FBG_LEVEL_DAILY — вчерашний дневной бар
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

//+------------------------------------------------------------------+
//| Вспомогательная функция отправки оповещения                      |
//+------------------------------------------------------------------+
void FireAlert(const string msg)
  {
   if(InpAlertPopup) Alert(msg);
   if(InpAlertSound) PlaySound(InpSoundFile);
   if(InpAlertPush)  SendNotification(msg);
   if(InpAlertEmail) SendMail("СуперТренд+Герчик", msg);
  }

//+------------------------------------------------------------------+
//| Основной расчёт                                                  |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   if(rates_total < 5) return 0;

   ComputeATR(rates_total, high, low, close);
   RebuildHTFTrend();

   int start;
   bool firstPass = (prev_calculated <= 1);
   if(firstPass)
     {
      ArrayInitialize(BufSTSolid,      EMPTY_VALUE);
      ArrayInitialize(BufSTEvasive,    EMPTY_VALUE);
      ArrayInitialize(BufSTSolidCol,   0);
      ArrayInitialize(BufSTEvasiveCol, 0);
      ArrayInitialize(BufSTBull,       EMPTY_VALUE);
      ArrayInitialize(BufSTBear,       EMPTY_VALUE);
      ArrayInitialize(BufCandleO,      0);
      ArrayInitialize(BufCandleH,      0);
      ArrayInitialize(BufCandleL,      0);
      ArrayInitialize(BufCandleC,      0);
      ArrayInitialize(BufCandleCol,    0);
      ArrayInitialize(BufFBGBuy,       EMPTY_VALUE);
      ArrayInitialize(BufFBGSell,      EMPTY_VALUE);
      ArrayInitialize(BufFBGCross,     EMPTY_VALUE);
      //--- (v2.03) новые буферы
      ArrayInitialize(BufHtfST,        EMPTY_VALUE);
      ArrayInitialize(BufHtfSTCol,     0);
      ArrayInitialize(BufFBGHigh,      EMPTY_VALUE);
      ArrayInitialize(BufFBGLow,       EMPTY_VALUE);
      ArrayInitialize(BufTrend,        1);
      ArrayInitialize(BufFU,           0);
      ArrayInitialize(BufFL,           0);
      ArrayInitialize(BufEvasive,      0);
      start = 1;
     }
   else
     {
      start = prev_calculated - 1;
      if(start < 1) start = 1;
     }

   //--- (правка #6) единый «пункт трейдера» с авто-коррекцией для 3/5-знаков
   double fbgOffset = (double)InpFBGOffsetPts * PipSize();

   //--- (правка #3) единый индекс бара для всех оповещений
   int alertBarIdx = InpAlertOnBarClose ? rates_total - 2 : rates_total - 1;

   for(int i=start; i<rates_total; ++i)
     {
      //================ Блок СуперТренда ============================
      double hl2 = (high[i] + low[i]) * 0.5;
      double atr = g_atr[i];
      double bu  = hl2 + InpBaseMultiplier*atr;
      double bl  = hl2 - InpBaseMultiplier*atr;
      double pu  = BufFU[i-1];
      double pl  = BufFL[i-1];
      double pc  = close[i-1];

      double fuRaw = (bu < pu || pc > pu) ? bu : pu;
      double flRaw = (bl > pl || pc < pl) ? bl : pl;
      double fu = fuRaw;
      double fl = flRaw;

      int prevTrend = (int)BufTrend[i-1];
      if(prevTrend == 0) prevTrend = 1;
      int trend;
      if(prevTrend == 1) trend = (close[i] < fl) ? -1 :  1;
      else               trend = (close[i] > fu) ?  1 : -1;

      bool evasive = false;
      double noiseDist = InpNoiseThreshold * atr;
      double expand    = InpExpansionAlpha * atr;
      double stValue;
      if(trend == 1)
        {
         double dist = close[i] - fl;
         if(dist < noiseDist && atr > 0.0) { fl -= expand; evasive = true; }
         stValue = fl;
        }
      else
        {
         double dist = fu - close[i];
         if(dist < noiseDist && atr > 0.0) { fu += expand; evasive = true; }
         stValue = fu;
        }

      if(InpEvasionPersist) { BufFU[i] = fu;    BufFL[i] = fl;    }
      else                  { BufFU[i] = fuRaw; BufFL[i] = flRaw; }

      BufTrend[i]   = trend;
      BufEvasive[i] = evasive ? 1.0 : 0.0;

      PlotST(i, stValue, trend, evasive);

      if(InpColorCandles)
        {
         BufCandleO[i]   = open[i];
         BufCandleH[i]   = high[i];
         BufCandleL[i]   = low[i];
         BufCandleC[i]   = close[i];
         BufCandleCol[i] = (trend == 1) ? 0 : 1;
        }

      //--- (v2.03 #11) линия HTF SuperTrend на основном графике
      BufHtfST[i]    = EMPTY_VALUE;
      BufHtfSTCol[i] = 0;
      if(InpUseHTF && InpDrawHtfST)
        {
         double htfSt; int htfCol;
         if(HTFLineAt(time[i], htfSt, htfCol))
           {
            BufHtfST[i]    = htfSt;
            BufHtfSTCol[i] = htfCol;
           }
        }

      //--- (правка #1) на самом первом обработанном баре нет надёжного
      //    предыдущего тренда: BufTrend[0] был засеян значением 1, и любой
      //    реальный медвежий старт давал бы ложный «флип». Подавляем.
      bool flipped = (i > 1) && (trend != prevTrend);

      BufSTBull[i] = EMPTY_VALUE;
      BufSTBear[i] = EMPTY_VALUE;
      if(flipped && InpShowSignals)
        {
         //--- (правка #7) HTF-фильтр через единый HTFAllows()
         if(trend ==  1 && HTFAllows(time[i],  1)) BufSTBull[i] = low[i]  - atr*0.5;
         else if(trend == -1 && HTFAllows(time[i], -1)) BufSTBear[i] = high[i] + atr*0.5;
        }

      //================ Блок ложного пробоя по Герчику =============
      BufFBGBuy[i]   = EMPTY_VALUE;
      BufFBGSell[i]  = EMPTY_VALUE;
      BufFBGCross[i] = EMPTY_VALUE;

      // только закрытые бары
      if(!InpFBGEnabled || i >= rates_total - 1) continue;

      double lh = 0, ll = 0;
      if(!GetFBGLevels(i, time, high, low, lh, ll)) continue;

      //--- (v2.03 #10) рисуем уровни HH/LL Герчика
      if(InpDrawFBGLevels)
        {
         BufFBGHigh[i] = lh;
         BufFBGLow[i]  = ll;
        }

      double body = MathAbs(close[i] - open[i]);
      double mid  = (high[i] + low[i]) * 0.5;

      bool isSell = false, isBuy = false;

      // ПРОДАЖА: ложный пробой сопротивления
      if(lh > 0.0 && high[i] > lh && close[i] < lh && close[i] < mid)
        {
         double tail = high[i] - lh;
         if(InpFBGMinTailATR <= 0.0 || atr <= 0.0 || tail >= atr * InpFBGMinTailATR)
            isSell = true;
        }
      // ПОКУПКА: ложный пробой поддержки
      if(ll > 0.0 && low[i] < ll && close[i] > ll && close[i] > mid)
        {
         double tail = ll - low[i];
         if(InpFBGMinTailATR <= 0.0 || atr <= 0.0 || tail >= atr * InpFBGMinTailATR)
            isBuy = true;
        }

      if(!isSell && !isBuy) continue;

      // фильтр чрезмерно импульсного бара — применяем только к стрелкам-сигналам.
      // Крест на встречном сигнале рисуем независимо от этого фильтра, чтобы
      // не терять предупреждение об ослаблении тренда на больших барах.
      bool bodyOk = !(InpFBGMaxBodyATR > 0.0 && atr > 0.0 && body > atr * InpFBGMaxBodyATR);

      //--- (правка #7) фильтр по тренду: учитываем И LTF-ST, И HTF-ST.
      //    sigSide = +1 для бычьего сигнала FBG, -1 для медвежьего.
      int  sigSide   = isBuy ? 1 : -1;
      bool ltfAgree  = (sigSide == trend);
      bool htfAgree  = HTFAllows(time[i], sigSide);
      bool withTrend = ltfAgree && htfAgree;          // согласие везде
      // counterTrend ⇔ есть противоречие на любом уровне
      // (ltf против ИЛИ htf против). Это и есть «раннее предупреждение
      //  ослабления тренда» — чем мы и хотели насытить крест.

      if(withTrend && bodyOk)
        {
         if(isBuy)  BufFBGBuy[i]  = low[i]  - fbgOffset;
         if(isSell) BufFBGSell[i] = high[i] + fbgOffset;

         if(!firstPass && InpAlertOnFBG && i == alertBarIdx
            && time[i] != g_lastFBGAlertTime)
           {
            g_lastFBGAlertTime = time[i];
            string side = isBuy ? "ПОКУПКА" : "ПРОДАЖА";
            FireAlert(StringFormat("Герчик %s (по тренду) | %s %s @ %s | уровень %s",
                       side, _Symbol, TfLabel((ENUM_TIMEFRAMES)_Period),
                       DoubleToString(close[i], _Digits),
                       DoubleToString(isBuy ? ll : lh, _Digits)));
            //--- (v2.03 #12) CSV-лог сигнала FBG (по тренду)
            if(InpLogFBG)
               LogSignal(time[i], "FBG", isBuy ? "BUY" : "SELL",
                         close[i], (isBuy ? ll : lh),
                         trend, HTFTrendAt(time[i]), evasive, atr);
           }
        }
      else
        {
         //--- (правка #4 + #7) если будем рисовать встречный крест,
         //    стрелку Герчика на этом же баре НЕ рисуем — они визуально
         //    налезают. Стрелка остаётся только когда крест отключён,
         //    а фильтр «только по тренду» — снят.
         bool drawCross = InpDrawCounterCross;

         if(!drawCross && !InpOnlyWithTrend && bodyOk)
           {
            if(isBuy)  BufFBGBuy[i]  = low[i]  - fbgOffset;
            if(isSell) BufFBGSell[i] = high[i] + fbgOffset;
           }

         if(drawCross)
           {
            //--- позиция креста: над high для встречи лонгу,
            //    под low — для встречи шорту. Привязка идёт к тому,
            //    КУДА смотрит сам сигнал FBG (sigSide), а не к LTF-trend,
            //    потому что HTF мог развернуться раньше LTF.
            if(sigSide == 1) BufFBGCross[i] = low[i]  - fbgOffset; // встречный лонг → крест под low
            else             BufFBGCross[i] = high[i] + fbgOffset; // встречный шорт → крест над high

            if(!firstPass && InpAlertOnCounter && i == alertBarIdx
               && time[i] != g_lastCrossAlertTime)
              {
               g_lastCrossAlertTime = time[i];
               string side  = (sigSide == 1) ? "шорта" : "лонга";
               string cause = !ltfAgree && !htfAgree ? "LTF+HTF"
                              : !ltfAgree            ? "LTF"
                              :                        "HTF";
               FireAlert(StringFormat("Герчик встречный сигнал против %s [%s] | %s %s @ %s",
                          side, cause, _Symbol, TfLabel((ENUM_TIMEFRAMES)_Period),
                          DoubleToString(close[i], _Digits)));
               //--- (v2.03 #12) CSV-лог встречного креста
               if(InpLogCounter)
                  LogSignal(time[i], "FBG_COUNTER", (sigSide == 1) ? "BUY" : "SELL",
                            close[i], (sigSide == 1) ? ll : lh,
                            trend, HTFTrendAt(time[i]), evasive, atr);
              }
           }
        }
     }

   //--- Одиночное оповещение о флипе СуперТренда (используем тот же alertBarIdx)
   if(alertBarIdx >= 1 && !firstPass)
     {
      int curTrend  = (int)BufTrend[alertBarIdx];
      int prevTrend = (int)BufTrend[alertBarIdx-1];
      datetime barT = time[alertBarIdx];
      if(curTrend != prevTrend && g_lastSTAlertTime != barT)
        {
         //--- (правка #7) единый HTFAllows() и здесь
         bool fireBuy  = (curTrend ==  1) && HTFAllows(barT,  1);
         bool fireSell = (curTrend == -1) && HTFAllows(barT, -1);
         if(fireBuy || fireSell)
           {
            g_lastSTAlertTime = barT;
            string side = fireBuy ? "БЫЧИЙ" : "МЕДВЕЖИЙ";
            FireAlert(StringFormat("СуперТренд %s флип | %s %s @ %s",
                       side, _Symbol, TfLabel((ENUM_TIMEFRAMES)_Period),
                       DoubleToString(close[alertBarIdx], _Digits)));
            //--- (v2.03 #12) CSV-журнал
            if(InpLogSTFlip)
               LogSignal(barT, "ST_FLIP", fireBuy ? "BUY" : "SELL",
                         close[alertBarIdx], 0.0,
                         curTrend, HTFTrendAt(barT), false, g_atr[alertBarIdx]);
           }
        }
     }

   //--- (правка #9 + v2.03 #13) обновляем бейдж HTF на каждом расчёте
   if(rates_total >= 1)
     {
      int    lastIdx    = rates_total - 1;
      int    lastTrend  = (int)BufTrend[lastIdx];
      bool   lastEvas   = (BufEvasive[lastIdx] > 0.5);
      UpdateHTFBadge(time[lastIdx], lastTrend, lastEvas);
     }

   return rates_total;
  }
//+------------------------------------------------------------------+
