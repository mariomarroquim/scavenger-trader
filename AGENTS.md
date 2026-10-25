# Scavenger Trader

A single-file Ruby script that runs a crypto scalping strategy against the Binance REST API,
trading ETH/BRL. There is no framework, no database, and no web server.

## The most important thing

`scavenger_trader.rb` is **generated output**, not hand-written source. The real source is the
prompt in `scavenger_trader.md`.

To change behaviour, edit `scavenger_trader.md` and regenerate the whole script from it, as the
spec itself instructs ("If `scavenger_trader.rb` already exists, delete it and fully regenerate
it from these specs"). Do not patch `scavenger_trader.rb` in place to add a feature, because the
next regeneration silently throws the patch away and the spec stops describing what actually runs.

Small corrections to the generated script are fine when the spec already describes the intended
behaviour and the script simply got it wrong. In that case, fix the script and leave the spec alone.

When regenerating, update `LLM_MODEL` to the model that produced the script.

## This script moves real money

`./start.sh` places live market buy and limit sell orders with real funds on a real Binance
account. Never run `start.sh`, `stop.sh`, or `ruby scavenger_trader.rb` to check your work, and
never call the Binance order endpoints directly. Verify changes by reading the code.

`stop.sh` and `start.sh` both run `pkill ruby`, which kills every Ruby process on the machine,
not just this one.

## Conventions

Readability first, then performance, then security. Comments explain *why* a decision was made,
above non-obvious logic only; the existing comments in `scavenger_trader.rb` set the bar for
density, so do not narrate what the code already says.

Prefer modern Ruby: endless methods for one-liners, safe navigation, keyword arguments,
`frozen_string_literal: true`. Settings belong in the global constants block at the top of the
file, never inlined at the call site.

All prices, quantities, and balances are `BigDecimal`. Never use `Float` for a value that touches
an order, and always round *down* to the exchange's tick size or step size, since rounding up gets
the order rejected or spends more than the account holds.

## Things that will bite you

Secrets come from the `BINANCE_API_KEY` and `BINANCE_API_SECRET` environment variables. Never
hardcode them, never log them, never echo them in a shell command.

The script must stay silent on STDOUT. Everything goes to `scavenger_trader.log` through `LOGGER`,
because `start.sh` detaches the process and discards its output. Order details are logged once per
status change, not once per poll.

Binance throttles aggressively, so every request goes through `BinanceClient#throttle` for a global
one-request-per-second cap. Any new endpoint call must go through the client rather than calling
HTTParty directly.

Error handling is deliberately split: `TransientError` and network errors retry every five minutes
for up to an hour, `BinanceError` means Binance refused the request and will not fix itself, and
anything else is logged as fatal before the script exits.

## Verification

There is no test suite, no linter, and no CI. `ruby -c scavenger_trader.rb` checks syntax safely
and is the only command worth running. Beyond that, review the diff by hand against
`scavenger_trader.md` and confirm the spec still describes what the script does.
