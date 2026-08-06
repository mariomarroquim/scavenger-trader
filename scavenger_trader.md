# Scavenger Trader

Act as an expert Ruby developer who values straightforward and performant code.
Automate a crypto scalping trading strategy that targets consistent, small gains.

### Strategy Overview
1. Place a market buy order using the available fiat balance.
2. Place a limit sell order using the available crypto balance.
3. Repeat the buy/sell cycle indefinitely.

### Technical Requirements
Write an executable Ruby script `scavenger_trader.rb` to trade ETH/BRL on Binance via REST API.
The script must run the following logic in a continuous loop:

1. **Buy Order Execution:**
   * Market buy crypto.
   * Wait for the buy order to fill.

2. **Sell Order Execution:**
   * Limit sell crypto at the last order's average buy price increased by 0.236%.
   * If this order doesn't fill after 5 hours, change its price to last order's avg. price + 0.175%.
   * Wait for the sell order to fill.

3. **Loop & Error Handling:**
   * Run the buy/sell cycle indefinitely.
   * Limit all REST API requests to 1 per second.
   * Keep skipping the buy/sell cycle if there are no available funds.
   * If the script fails for network reasons, retry requests after 5 minutes for up to 5 hours.
   * If the script fails for any other reason, log the error and exit the script.

4. **Logging:**
   * Log both script execution starting and ending.
   * Don't print messages to STDOUT (e.g., avoid using `puts`).
   * Append all log items to `scavenger_trader.log`, prefixed with the current time.
   * Append order details (type, side, symbol, price, quantity) once per status change.

5. **API Authentication:**
   * Get API key and secret from environment variables `BINANCE_API_KEY` and `BINANCE_API_SECRET`.

6. **Implementation details:**
   * Settings must be defined as global constants.
   * Add the AI LLM model name and version to the script.
   * Use the `httparty` Ruby gem to perform all HTTP REST requests.
   * Round down prices and quantities to the maximum allowed precision for each asset.
