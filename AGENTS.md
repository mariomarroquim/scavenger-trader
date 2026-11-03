# Scavenger Trader

Scavenger Trader is a Ruby script that trades ETH/BRL using a scalping strategy on Binance.

## Project details

### The most important thing

`scavenger_trader.rb` is **generated output**, not hand-written source. The real source is the
prompt in `scavenger_trader.md`.

To change behavior, edit `scavenger_trader.md` and regenerate the whole script from it, as the
spec itself instructs ("If `scavenger_trader.rb` already exists, delete and regenerate it from
these specs"). Do not patch `scavenger_trader.rb` in place to add a feature, because the next
regeneration silently throws the patch away and the spec stops describing what actually runs.

Small corrections to the generated script are fine when the spec already describes the intended
behavior and the script simply got it wrong. In that case, fix the script and leave the spec alone.

When regenerating, update `LLM_MODEL` to the model that produced the script.

### This script moves real money

`./start.sh` places live limit buy, limit sell, and market sell orders with real funds on a real
Binance account. Never run `start.sh`, `stop.sh`, or `ruby scavenger_trader.rb` to check your work,
and never call the Binance order endpoints directly. Verify changes by reading the code.

`stop.sh` and `start.sh` both run `pkill ruby`, which kills every Ruby process on the machine,
not just this one.

### Things that will bite you

Secrets come from the `BINANCE_API_KEY` and `BINANCE_API_SECRET` environment variables. Never
hardcode them, never log them, never echo them in a shell command.

The script must stay silent on STDOUT. Everything goes to `scavenger_trader.log` through `LOGGER`,
because `start.sh` detaches the process and discards its output. Order details are logged once per
status change, not once per poll.

Binance throttles aggressively, so every request goes through `BinanceClient#throttle` for a global
one-request-per-second cap. Any new endpoint call must go through the client rather than calling
HTTParty directly.

Error handling is deliberately split: `TransientError` and network errors retry every five minutes
for up to an hour and then raise `NetworkError`, while `BinanceError` means Binance refused the
request and will not fix itself. Both of those, and anything else, are logged as fatal before the
script exits. The one exception is a refused cancel, which `ScavengerTrader#cancel` rescues because
the order may have filled in the meantime.

## Code conventions

- Don't add any new dependencies without asking first.
- If the code changes, sync both `AGENTS.md` and `README.md` as well.
- Run `ruby -c scavenger_trader.rb` to check for errors before every commit.
- Don't commit and push changes unless explicitly required.
- This project only uses the `main` branch; commit and push directly to it.
