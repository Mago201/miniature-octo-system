# Как работает связка Алиса <-> Recovery (Variant 2)

> Источники в репозитории: `Алиса_MT5.mq5` v5.2 (ветка `feat/alisa-fixes`),
> `RecoveryEA.mq5` v1.20 (ветка `feat/recovery-handoff`), `INTEGRATION.md`.

## Зачем эта пара

* **Алиса** — боевая «торговая голова»: открывает позиции, управляет ими,
  имеет три магика стратегий (например `852791,852792,852793`).
* **Recovery EA** — «реанимация»: умеет усреднять, делать smart-partial
  («лучший плюс + худший минус >= доли цели -> закрываем пару»),
  trailing-target и cross-basket close. Сам по себе ничего не открывает.
* Идея: пока всё хорошо — Алиса торгует одна, Recovery дремлет.
  Как только просадка пробивает порог — Алиса передаёт свои корзины
  Recovery и сама засыпает. Recovery их вытаскивает в плюс,
  отчитывается, Алиса просыпается.

Оба EA должны висеть на одном символе в одном терминале MT5.
Связь — через Global Variables (общие на терминал, переживают рестарт).
Никакого DLL/файлов.

## Протокол (3 GV)

| GV                       | Кто пишет | Кто читает       | Семантика                                    |
| ------------------------ | --------- | ---------------- | -------------------------------------------- |
| `Alisa.Halt`             | Алиса     | оба              | 1 — Алиса в DD-стопе, Recovery, выходи       |
| `Alisa.AttachEquity`     | Алиса     | Recovery         | equity на момент halt, информационно         |
| `Alisa.Recovery.Active`  | Recovery  | Алиса            | 1 пока у Recovery в работе хоть одна позиция |

Все три — `GlobalVariableTemp` (не пишутся в файл, но переживают
рестарт через рантайм-механизм MT5).

## Конечный автомат

### Алиса (`CheckAndManageDrawdownLock` каждый тик)

```
DD% = (Balance - Equity) / Balance * 100

if UseRecoveryHandoff:
    if not halted:
        if DD% >= HandoffMinDD (5%):
            GV Alisa.Halt = 1
            GV Alisa.AttachEquity = equity
            -> переходим в halt
    else:
        recoveryDone = (Alisa.Recovery.Active == 0)
        if recoveryDone and DD% < HandoffResumeDD (2%):
            del Alisa.Halt, Alisa.AttachEquity
            -> возврат в торговлю
else:
    # старый путь — встречный лок (legacy),
    # отключается автоматом, если handoff включён
```

В состоянии halted Алиса не открывает новых сделок и не усредняет.
Закрытие глобального TP/SL $/% (если настроен) всё ещё работает —
и если оно сработает и обнулит позиции, halt сбрасывается, чтобы
Алиса не висела вечно (решение Q2: «глобал-клоуз сбрасывает halt»).

### Recovery (`Cycle()` каждый тик/таймер)

```
1) CheckHardStop()  -> если equity < attachEquity * (1-25%),
                       закрываем всё, замораживаемся
2) посчитать корзины BUY/SELL по своим адоптным магикам
3) HANDOFF-gate:
       alisaHalted = (Alisa.Halt == 1)
       weHavePos   = (basket non-empty)
       if InpHandoffEnabled and InpHandoffOnlyWhenAlisaHalted
          and not alisaHalted and not weHavePos:
              Alisa.Recovery.Active = 0
              -> выходим, ничего не делаем (тихий режим)
4) cross-basket TP -> возможно закрыть всё
5) для каждой стороны (BUY/SELL):
       TryCloseBasket  (TP по деньгам/%/пипсам, с trailing)
       TrySmartPartial (если набралось >= InpMinTradesForPart)
       TryAverage      (добавка по шагу ATR/пипс с растущим лотом)
6) Alisa.Recovery.Active = (есть сопровождаемые позиции?)
```

#### Что значит «адоптировать» (`BelongsToBasket`)

* `ADOPT_BY_MAGIC_LIST` — Recovery присваивает себе позицию, если её
  magic есть в `InpAdoptMagicsCSV` (магики Алисы) или это `InpMagic`
  (свои усреднения). Это рабочий режим.
* `ADOPT_OWN_MAGIC` — только свои.
* `ADOPT_ALL_FOREIGN` — все позиции по символу. В боевом протоколе
  не используется, оставлен для свободного запуска без Алисы.

Recovery не закрывает существующие позиции Алисы насильно — они
продолжают жить со своим magic, просто Recovery «приклеивает» их
в свой бухгалтерский учёт корзины и довешивает усреднения от
своего `InpMagic`. Закроется корзина целиком (или smart-partial по
парам) — закроются все, в том числе оригинальные ордера Алисы.

## Хронология одного цикла «беда -> рекавери -> возврат»

1. **Норма.** Алиса торгует. `Alisa.Halt` отсутствует/0. Recovery
   видит `halted=0` и `basket=0` -> публикует `Active=0`,
   висит в Comment с пометкой Handoff и спит.
2. **Просадка растёт до 5%.** Алиса в `CheckAndManageDrawdownLock`:
   ставит `Alisa.Halt=1`, `Alisa.AttachEquity=equity`, больше не торгует.
3. **Recovery активируется.** Следующим тиком увидит `Alisa.Halt=1`,
   перестанет проваливаться через handoff-gate, посчитает корзины.
   Адоптировал позиции с магиками Алисы -> `Active=1`.
4. **Recovery работает:**
   * Если цена дошла до шага `ATR*Mult` или фикс. пипсов от худшей
     цены и кулдаун `InpAddCooldownSec` истёк — добавляет усреднение
     лотом `prev * 1.3` (с потолками `InpMaxLotPerTrade`,
     `InpMaxBasketVolume`, `InpMaxTradesInGrid`).
   * Если суммарный PL корзины >= `InpTpMoney` (или %, или взвеш. пипсов) —
     взводит трейл; закрывает корзину, когда PL отдал
     `InpTrailGivebackPct` от пика.
   * Опц. Smart partial: если в корзине >= `InpMinTradesForPart` сделок и
     (макс. плюс + макс. минус) >= `InpPartialFraction * tpTarget` —
     закрывает только эту пару, продолжает работу.
   * Опц. ST-фильтр: добавки разрешены только в сторону тренда
     EvasiveST_FBG (читается buffer #14 = `BufTrend`, shift=1,
     look-ahead-safe).
   * Hard-stop: если equity упала ниже `attachEquity * (1 - 25%)` —
     Recovery закрывает всё, ставит `g_frozen=true` и до перезапуска
     не оживает.
5. **Корзина опустела.** Recovery: `Active=0`. Алиса в
   `CheckAndManageDrawdownLock`: видит `Active=0` и текущий DD < 2%
   (`HandoffResumeDD`) -> удаляет `Alisa.Halt`/`Alisa.AttachEquity` ->
   возвращается в торговлю.
6. **Дальше — пункт 1.**

## Граничные случаи, которые код сам обрабатывает

* **Рестарт терминала.** GV переживают перезапуск, поэтому если Алиса
  упала в halt, ты закрыл MT5 и открыл его заново — оба EA продолжат
  с того же места: Алиса всё ещё halted, Recovery всё ещё Active.
* **Recovery первым стартует, а Алисы нет.** При
  `InpHandoffOnlyWhenAlisaHalted=true` Recovery просто молчит, пока
  кто-то не выставит `Alisa.Halt=1`. Если включить
  `InpHandoffOnlyWhenAlisaHalted=false`, можно гонять Recovery как
  самостоятельный EA, но тогда Алиса должна быть выключена.
* **Закрытие всего руками или глобальным TP $/%.** Алиса очистит
  свой halt сама (Q2: «глобал-клоуз сбрасывает halt»), Recovery
  увидит пустую корзину -> `Active=0`. Без этого Алиса бы висела
  навечно.
* **Hard-stop Recovery.** Если просадка ушла ниже -25% от
  attach-equity — Recovery срубит всё и заморозится. Алиса увидит
  `Active=0` и (если DD укладывается в `HandoffResumeDD`) проснётся.
  Если DD всё ещё большая — Алиса останется в halt, но новых
  корзин нет, нужно вмешательство.
* **Netting-счёт.** Оба EA про это знают и пишут warning в журнал.
  Smart partial по парам не работает (на нетинге одна суммарная
  позиция), но усреднения и trailing target работают.
* **Изменение CSV магиков на лету.** Не делай так — список парсится
  в `OnInit`. Поменял — рестартни Recovery.

## Чек-лист настроек, чтобы заработало

### Алиса

```
UseRecoveryHandoff   = true
HandoffMinDD         = 5.0
HandoffResumeDD      = 2.0          # обязательно < HandoffMinDD
HandoffMagicsCSV     = "852791,852792,852793"
UseDrawdownLock      = true         # можно оставить — отключается автоматом
                                    # при UseRecoveryHandoff=true
```

### Recovery (на том же символе)

```
InpAdoptionMode               = ADOPT_BY_MAGIC_LIST
InpAdoptMagicsCSV             = "852791,852792,852793"   # ровно как у Алисы
InpHandoffEnabled             = true
InpHandoffOnlyWhenAlisaHalted = true
InpHandoffPublishActive       = true
```

### Нюансы Recovery, которые стоит подумать под свой счёт

* `InpStepMode=STEP_ATR`, `InpAtrMult=1.0` — шаг ~= 1 ATR (H1 по умолчанию).
  Для волатильных пар увеличь.
* `InpLotMultiplier=1.3` — мартингейл-лайт. Жёсткий cap корзины —
  `InpMaxBasketVolume=5.0` лот, `InpMaxTradesInGrid=12`.
* `InpTpMode=TP_MONEY`, `InpTpMoney=50` — закрытие при +$50 на корзину.
  Для крупных депо переключись на `TP_PERCENT_BAL` (1% от баланса) —
  масштабируется само.
* `InpMaxAttachDDPct=25` — это твой парашют. Именно отсюда взять
  предельный риск, который ты готов отдать за реанимацию.

## Чего нельзя делать

* **Двух Алис** на один символ с handoff — будут драться за
  `Alisa.Halt`. На одном чарте Алиса + Recovery — это и есть
  правильная схема.
* **Менять магики при открытой корзине** — Recovery уже распарсил
  их в `OnInit`.
* **Запускать Recovery с `InpHandoffOnlyWhenAlisaHalted=false`
  параллельно с работающей Алисой** — он подхватит её живые позиции
  и начнёт их усреднять, хотя Алиса ещё не сдалась. Это уже не
  «передача корзины», а конфликт стратегий.
