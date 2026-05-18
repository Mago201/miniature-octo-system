# Алиса ⇄ Recovery handoff (Variant 2)

EAs: **Алиса_MT5.mq5 v5.2** + **RecoveryEA.mq5 v1.20**.

Both must run **on the same symbol, same MT5 terminal**. Communication is via Global Variables (GV) — they are shared across all EAs on this terminal and survive a terminal restart.

## GV protocol

| GV name                  | Writer    | Reader            | Meaning                                                    |
|--------------------------|-----------|-------------------|------------------------------------------------------------|
| `Alisa.Halt`             | Алиса     | Алиса + Recovery  | `1` while Алиса is in DD-stop and asks Recovery to step in |
| `Alisa.AttachEquity`     | Алиса     | Recovery          | Account equity at the moment of halt (informational)       |
| `Alisa.Recovery.Active`  | Recovery  | Алиса             | `1` while Recovery has any adopted positions               |

## State machine

```
Алиса:
  while Halt == 0:
      trade normally
      if DD% >= HandoffMinDD:
          Halt := 1; AttachEquity := equity   // hand off
  while Halt == 1:
      do not open / do not average
      if Recovery.Active == 0 and DD% < HandoffResumeDD:
          Halt := 0                            // resume

Recovery:
  while Halt == 0 and basket is empty:
      stay passive (publish Active=0)
  while Halt == 1 or basket is non-empty:
      adopt positions matching InpAdoptMagicsCSV
      run averaging / smart partial / trailing target
      publish Active = (basket non-empty)
```

## Configuration checklist

### Алиса_MT5.mq5
- `UseRecoveryHandoff = true`
- `HandoffMinDD = 5.0` (or your trigger)
- `HandoffResumeDD = 2.0` (must be < HandoffMinDD)
- `HandoffMagicsCSV = "852791,852792,852793"` (your strategy magics)
- `UseDrawdownLock = true` is OK — it is automatically bypassed when handoff fires; legacy lock is only used if `UseRecoveryHandoff = false`.

### RecoveryEA.mq5
- `InpAdoptionMode = ADOPT_BY_MAGIC_LIST`
- `InpAdoptMagicsCSV = "852791,852792,852793"` (must match Алиса)
- `InpHandoffEnabled = true`
- `InpHandoffOnlyWhenAlisaHalted = true` (Recovery будет тих, пока Алиса не позовёт)
- `InpHandoffPublishActive = true`
- Choose averaging parameters appropriate for the basket size you expect Алиса to leave behind.

## Hedging vs netting

Tested scenario: **hedging account**. On netting accounts:
- Алиса's legacy lock would not work anyway (opposite-direction order nets out).
- Handoff still works in principle, but Recovery's smart-partial close has nothing to pair (only one net position per symbol). Averaging and trailing target are unaffected.

## Restart behaviour

- GVs persist across terminal restarts. If Алиса halted, terminal closed, and you start it back: Алиса resumes in halted state, Recovery resumes in active state — no spurious activity.
- If you want to force-reset: delete GVs `Alisa.Halt`, `Alisa.Recovery.Active`, `Alisa.AttachEquity` from `Tools → Global Variables`.

## Operating notes

- **Do not run two Алисы** on the same symbol with handoff enabled — they will fight over `Alisa.Halt`. Recovery as second EA on same symbol is the intended setup.
- **Do not change magics** while a basket is open — Recovery's adoption list is parsed at OnInit. After changing, restart Recovery.
- Global close ($/%) in Алиса is honored even during halt; if it triggers, Алиса clears its own halt state so Recovery will see Active=0 next tick.
