#!/usr/bin/env ruby
# frozen_string_literal: true

require 'httparty'
require 'openssl'
require 'json'
require 'logger'
require 'time'

# ==============================================================================
# SCRIPT METADATA & CONFIGURATION CONSTANTS
# ==============================================================================
AI_MODEL_NAME            = 'Gemini 2.5 Pro'
LOG_FILE                 = 'scavenger_trader.log'

# Trading Pair Settings
SYMBOL                   = 'ETHBRL'
BASE_ASSET               = 'ETH'
QUOTE_ASSET              = 'BRL'

# Strategy Profit Margins & Timers
TARGET_GAIN_PCT          = 0.00382 # +0.382% initial limit sell margin
TIMEOUT_PRICE_INC_PCT    = 0.00175 # +0.175% price increase on timeout
SELL_TIMEOUT_SECONDS     = 3600    # 1 hour timeout before re-pricing

# Operational Constants
RATE_LIMIT_DELAY         = 1.0     # Maximum 1 REST request per second
NETWORK_RETRY_DELAY      = 60      # Wait 1 minute on network failure
POLL_INTERVAL            = 3.0     # Interval between order status checks
MIN_NOTIONAL_BRL         = 10.0    # Minimum BRL trade value safety threshold

# Binance REST API Base URL
BINANCE_BASE_URL         = 'https://api.binance.com'

# Environment Credentials
API_KEY                  = ENV['BINANCE_API_KEY']
API_SECRET               = ENV['BINANCE_API_SECRET']

# Network Errors for specialized retry logic
NETWORK_ERRORS = [
  SocketError,
  Errno::ECONNREFUSED,
  Errno::ECONNRESET,
  Errno::ETIMEDOUT,
  Net::ReadTimeout,
  Net::OpenTimeout,
  HTTParty::Error
].freeze

# ==============================================================================
# LOGGER SETUP (NO STDOUT)
# ==============================================================================
LOGGER = Logger.new(LOG_FILE)
LOGGER.formatter = proc do |severity, datetime, _progname, msg|
  "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{severity}: #{msg}\n"
end

# Ensure credentials exist before starting
if API_KEY.nil? || API_KEY.strip.empty? || API_SECRET.nil? || API_SECRET.strip.empty?
  LOGGER.fatal('Missing BINANCE_API_KEY or BINANCE_API_SECRET environment variables.')
  exit 1
end

# ==============================================================================
# BINANCE API CLIENT
# ==============================================================================
class BinanceClient
  include HTTParty
  base_uri BINANCE_BASE_URL

  def initialize
    @last_request_time = Time.at(0)
  end

  def request(method, path, params = {}, signed: false)
    enforce_rate_limit

    headers = { 'X-MBX-APIKEY' => API_KEY }
    query_params = params.dup

    if signed
      query_params[:timestamp] = (Time.now.to_f * 1000).to_i
      query_string = URI.encode_www_form(query_params)
      query_params[:signature] = OpenSSL::HMAC.hexdigest('sha256', API_SECRET, query_string)
    end

    response = self.class.send(method, path, headers: headers, query: query_params)

    unless response.success?
      raise "Binance API Error [#{response.code}]: #{response.body}"
    end

    response.parsed_response
  end

  private

  def enforce_rate_limit
    elapsed = Time.now - @last_request_time
    sleep(RATE_LIMIT_DELAY - elapsed) if elapsed < RATE_LIMIT_DELAY
    @last_request_time = Time.now
  end
end

# ==============================================================================
# TRADER AGENT CLASS
# ==============================================================================
class ScavengerTrader
  def initialize
    @client = BinanceClient.new
    @tick_size = nil
    @step_size = nil
  end

  def run
    LOGGER.info("Scavenger Trader starting up... (LLM: #{AI_MODEL_NAME})")
    LOGGER.info("Target Symbol: #{SYMBOL} | Target Gain: #{TARGET_GAIN_PCT * 100}%")

    fetch_exchange_precisions

    loop do
      execute_cycle
    end
  rescue Interrupt
    LOGGER.info('Execution interrupted by user/system signal.')
  rescue StandardError => e
    LOGGER.fatal("Fatal unhandled error: #{e.message}\n#{e.backtrace.join("\n")}")
    exit 1
  ensure
    LOGGER.info('Scavenger Trader script execution ending.')
  end

  private

  def execute_cycle
    # --------------------------------------------------------------------------
    # 1. CHECK FIAT BALANCE & BUY
    # --------------------------------------------------------------------------
    quote_balance = fetch_asset_balance(QUOTE_ASSET)

    if quote_balance < MIN_NOTIONAL_BRL
      LOGGER.warn("Insufficient #{QUOTE_ASSET} balance (#{quote_balance}). Waiting for funds...")
      sleep(10)
      return
    end

    LOGGER.info("Available #{QUOTE_ASSET} balance: #{quote_balance}. Placing Market Buy...")
    buy_order = safe_api_call do
      @client.request(:post, '/api/v3/order', {
        symbol: SYMBOL,
        side: 'BUY',
        type: 'MARKET',
        quoteOrderQty: round_down(quote_balance, @tick_size)
      }, signed: true)
    end

    buy_details = wait_for_order_fill(buy_order['orderId'])
    executed_qty = buy_details['executedQty'].to_f
    cummulative_quote = buy_details['cummulativeQuoteQty'].to_f
    avg_buy_price = cummulative_quote / executed_qty

    LOGGER.info("Buy order filled: #{executed_qty} #{BASE_ASSET} at avg price #{avg_buy_price} #{QUOTE_ASSET}")

    # --------------------------------------------------------------------------
    # 2. LIMIT SELL EXECUTION WITH PRICE INCREMENT TIMEOUT
    # --------------------------------------------------------------------------
    current_target_price = round_down(avg_buy_price * (1.0 + TARGET_GAIN_PCT), @tick_size)

    loop do
      crypto_balance = fetch_asset_balance(BASE_ASSET)
      sell_qty = round_down([executed_qty, crypto_balance].min, @step_size)

      if sell_qty <= 0
        LOGGER.warn("No available #{BASE_ASSET} balance to sell. Exiting sell cycle.")
        break
      end

      LOGGER.info("Placing Limit Sell order: #{sell_qty} #{BASE_ASSET} @ #{current_target_price} #{QUOTE_ASSET}")
      sell_order = safe_api_call do
        @client.request(:post, '/api/v3/order', {
          symbol: SYMBOL,
          side: 'SELL',
          type: 'LIMIT',
          timeInForce: 'GTC',
          quantity: sell_qty,
          price: current_target_price
        }, signed: true)
      end

      sell_result = wait_for_sell_or_timeout(sell_order['orderId'], SELL_TIMEOUT_SECONDS)

      if sell_result[:status] == 'FILLED'
        LOGGER.info("Limit Sell order filled completely @ #{current_target_price}!")
        break
      elsif sell_result[:status] == 'EXPIRED_TIMEOUT'
        LOGGER.warn("Limit Sell order timed out after 1h. Cancelling and increasing price by #{TIMEOUT_PRICE_INC_PCT * 100}%...")

        safe_api_call do
          @client.request(:delete, '/api/v3/order', { symbol: SYMBOL, orderId: sell_order['orderId'] }, signed: true)
        end

        current_target_price = round_down(current_target_price * (1.0 + TIMEOUT_PRICE_INC_PCT), @tick_size)
      end
    end
  end

  # Fetch symbol precision rules (PRICE_FILTER and LOT_SIZE)
  def fetch_exchange_precisions
    LOGGER.info("Fetching market precision rules for #{SYMBOL}...")
    info = safe_api_call do
      @client.request(:get, '/api/v3/exchangeInfo', { symbol: SYMBOL })
    end

    symbol_info = info['symbols'].find { |s| s['symbol'] == SYMBOL }
    price_filter = symbol_info['filters'].find { |f| f['filterType'] == 'PRICE_FILTER' }
    lot_filter   = symbol_info['filters'].find { |f| f['filterType'] == 'LOT_SIZE' }

    @tick_size = price_filter['tickSize'].to_f
    @step_size = lot_filter['stepSize'].to_f
    LOGGER.info("Precision loaded - Tick Size: #{@tick_size}, Step Size: #{@step_size}")
  end

  def fetch_asset_balance(asset)
    account_info = safe_api_call do
      @client.request(:get, '/api/v3/account', {}, signed: true)
    end

    balance_entry = account_info['balances'].find { |b| b['asset'] == asset }
    balance_entry ? balance_entry['free'].to_f : 0.0
  end

  def wait_for_order_fill(order_id)
    last_status = nil

    loop do
      order = safe_api_call do
        @client.request(:get, '/api/v3/order', { symbol: SYMBOL, orderId: order_id }, signed: true)
      end

      current_status = order['status']

      if current_status != last_status
        LOGGER.info("Order status change -> ID: #{order['orderId']} | Type: #{order['type']} | " \
                    "Side: #{order['side']} | Symbol: #{order['symbol']} | Price: #{order['price']} | " \
                    "Qty: #{order['origQty']} | Status: #{current_status}")
        last_status = current_status
      end

      return order if current_status == 'FILLED'

      sleep(POLL_INTERVAL)
    end
  end

  def wait_for_sell_or_timeout(order_id, timeout_duration)
    start_time = Time.now
    last_status = nil

    loop do
      order = safe_api_call do
        @client.request(:get, '/api/v3/order', { symbol: SYMBOL, orderId: order_id }, signed: true)
      end

      current_status = order['status']

      if current_status != last_status
        LOGGER.info("Order status change -> ID: #{order['orderId']} | Type: #{order['type']} | " \
                    "Side: #{order['side']} | Symbol: #{order['symbol']} | Price: #{order['price']} | " \
                    "Qty: #{order['origQty']} | Status: #{current_status}")
        last_status = current_status
      end

      return { status: 'FILLED', order: order } if current_status == 'FILLED'

      if Time.now - start_time >= timeout_duration
        return { status: 'EXPIRED_TIMEOUT', order: order }
      end

      sleep(POLL_INTERVAL)
    end
  end

  # High-precision floor method for prices and quantities
  def round_down(value, step)
    return value if step.nil? || step.zero?

    precision = Math.log10(1.0 / step).round
    factor = 10.0**precision
    (value * factor).floor / factor
  end

  # Wrapper to handle transient network errors with 1-minute retry logic
  def safe_api_call
    yield
  rescue *NETWORK_ERRORS => e
    LOGGER.warn("Network error encountered: #{e.message}. Retrying in #{NETWORK_RETRY_DELAY} seconds...")
    sleep(NETWORK_RETRY_DELAY)
    retry
  end
end

# ==============================================================================
# ENTRY POINT
# ==============================================================================
if __FILE__ == $0
  ScavengerTrader.new.run
end
