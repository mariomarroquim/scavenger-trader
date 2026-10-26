# Scavenger Trader

Act as an expert Ruby developer who values straightforward and performant code.
Automate a crypto scalping trading strategy that targets consistent, small gains over time.

## Strategy Overview

1. Place a limit buy order using the available fiat balance.
2. Place a limit sell order using the available crypto balance.
3. Repeat the buy/sell cycle indefinitely until exit conditions are met.

## Technical Requirements

Write the executable Ruby script `scavenger_trader.rb` to trade ETH/BRL on Binance via REST API.
If `scavenger_trader.rb` already exists, delete and regenerate it from these specs.
The script must run the following logic in a continuous loop:

1. **Buy Order Execution:**
   * Limit buy crypto at the current avg. buy price - 0.075%.
   * Wait for the buy order to fill.

2. **Sell Order Execution:**
   * Limit sell crypto at the last buy order avg. price + 0.225%.
   * If unfilled after an hour, change it to last buy order avg. price + 0.150%.
   * If still unfilled after another hour, market sell all the available crypto balance.
   * Wait for the sell order to fill and restart the cycle indefinitely until exit conditions are met.

3. **Loop & Error Handling:**
   * Run the buy/sell cycle indefinitely.
   * Limit all REST API requests to around 1 per second.
   * Keep skipping the buy/sell cycle if there are no available funds.
   * If the script fails for network reasons, retry every 5 minutes for an hour.
   * If the script fails for any other reason, log the error and exit the script gracefuly.

4. **Logging:**
   * Log both script execution starting and ending.
   * Don't print messages to STDOUT (e.g., avoid using `puts`).
   * Append all log items to `scavenger_trader.log`, prefixed with date & time.

5. **API Authentication:**
   * Get API key and secret from environment variables `BINANCE_API_KEY` and `BINANCE_API_SECRET`.

6. **Implementation/Testing details:**
   * Settings must be defined as global constants.
   * Add the AI LLM model name and version to the script.
   * Use the `httparty` Ruby gem to perform all HTTP REST requests.
   * Round down prices and quantities to the maximum allowed precision for each asset.
   * Don't run or start the implementation for testing. Just use `ruby -c` to check for correctness.

