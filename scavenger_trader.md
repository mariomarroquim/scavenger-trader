Act as an expert Ruby developer who values straightforward and performant code.
Automate a Crypto scalping trading strategy that targets consistent, small gains.

### Strategy Overview
1. Place a limit buy order using the available Fiat balance.
2. Place a limit sell order using the available Crypto balance.
3. Repeat the buy/sell cycle indefinitely.

### Technical Requirements
Write an executable Ruby script `scavenger_trader.rb` to trade ETH/BRL on Binance via REST API.
The script must run the following logic in a continuous loop:

1. **Buy Order Execution:**
   * Limit buy Crypto at current price - 0.382% (Fibonacci 38.2% retracement ratio).
   * Wait for the buy order to fill.

2. **Sell Order Execution:**
   * Limit sell Crypto at last order's buy price + 0.236% (Fibonacci 23.6% retracement ratio).
   * Wait for the sell order to fill.

3. **Loop & Error Handling:**
   * Run the buy/sell cycle indefinitely.
   * Limit all REST API requests to 1 per 1 second.
   * Keep skipping buy/sell cycle if there are no available funds.
   * If the script fails for network reasons, retry requests after 1 minute.
   * If the script fails for any other reason, log the error and exit the script.

4. **Logging:**
   * Log both script execution starting and ending.
   * Don't print messages to STDOUT (e.g., avoid using `puts`).
   * Append all log items to `scavenger_trader.log`, prefixed with the current time.
   * Append order details (type, side, symbol, price, quantity) once per status change.

5. **API Authentication:**
   * Get API key and secret from env. vars `BINANCE_API_KEY` and `BINANCE_API_SECRET`.

6. **Implementation details:**
   * Settings must be defined as global constants.
   * Add the AI LLM model name and version to the script.
   * Use `httparty` Ruby gem to perform all HTTP REST requests.
   * Round down prices and quantities to the maximum allowed precision for each asset.
