#!/usr/bin/env ruby
# frozen_string_literal: true

require 'httparty'
require 'openssl'
require 'json'
require 'logger'
require 'time'

# ==============================================================================
# GLOBAL CONFIGURATION & CONSTANTS
# ==============================================================================
AI_MODEL_NAME = 'Gemini 2.5 Flash'
AI_MODEL_VERSION = '2026-02'

SYMBOL = 'ETHBRL'
BASE_ASSET = 'ETH'
QUOTE_ASSET = 'BRL'

BUY_DISCOUNT_PCT = 0.00236  # 0.236%
SELL_PROFIT_PCT   = 0.00236  # 0.236%

ORDER_TIMEOUT_SECONDS = 3600  # 1 hour
RATE_LIMIT_DELAY     = 1.0   # Minimum 1 second between API calls
NETWORK_RETRY_DELAY  = 60    # 1 minute retry on network failure
POLL_INTERVAL        = 5.0   # Order status polling interval

BASE_URL = 'https://api.binance.com'
LOG_FILE = 'scavenger_trader.log'

# API Key Authentication from Environment Variables
API_KEY    = ENV.fetch('BINANCE_API_KEY', nil)
API_SECRET = ENV.fetch('BINANCE_API_SECRET', nil)

# ==============================================================================
# SCAVENGER TRADER CLASS
# ==============================================================================
class ScavengerTrader
  def initialize
    setup_logger
    validate_credentials!

    @last_request_time = 0.0
    @price_precision = 2
    @quantity_precision = 4
    @last_logged_statuses = {}
  end

  def run
    @logger.info("Starting Scavenger Trader [Model: #{AI_MODEL_NAME} v#{AI_MODEL_VERSION}] for symbol #{SYMBOL}")
    fetch_symbol_precisions

    loop do
      execute_cycle
    rescue SystemExit
      raise
    rescue StandardError => e
      @logger.error("Fatal unhandled error: #{e.class} - #{e.message}")
      @logger.error(e.backtrace.join("\n"))
      exit(1)
    end
  end

  private

  # Set up logger with strict instructions to NOT print to STDOUT
  def setup_logger
    @logger = Logger.new(LOG_FILE, datetime_format: '%Y-%m-%d %H:%M:%S')
    @logger.formatter = proc do |severity, datetime, _progname, msg|
      "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{severity}: #{msg}\n"
    end
  end

  def validate_credentials!
    if API_KEY.nil? || API_KEY.strip.empty? || API_SECRET.nil? || API_SECRET.strip.empty?
      @logger.error('Missing API credentials. Ensure BINANCE_API_KEY and BINANCE_API_SECRET environment variables are set.')
      exit(1)
    end
  end

  # ============================================================================
  # NETWORK & REST API HANDLING
  # ============================================================================
  def rate_limited_request
    now = Time.now.to_f
    elapsed = now - @last_request_time
    sleep_time = RATE_LIMIT_DELAY - elapsed
    sleep(sleep_time) if sleep_time > 0
    @last_request_time = Time.now.to_f
    yield
  end

  def send_request(http_method, path, params = {}, is_private: false)
    rate_limited_request do
      url = "#{BASE_URL}#{path}"
      headers = {}

      if is_private
        headers['X-MBX-APIKEY'] = API_KEY
        params[:timestamp] = (Time.now.to_f * 1000).to_i
        query_string = URI.encode_www_form(params)
        signature = OpenSSL::HMAC.hexdigest('sha256', API_SECRET, query_string)
        query_string += "&signature=#{signature}"
      else
        query_string = URI.encode_www_form(params)
      end

      full_url = query_string.empty? ? url : "#{url}?#{query_string}"

      with_network_retry do
        response = case http_method
                   when :get    then HTTParty.get(full_url, headers: headers, timeout: 10)
                   when :post   then HTTParty.post(full_url, headers: headers, timeout: 10)
                   when :delete then HTTParty.delete(full_url, headers: headers, timeout: 10)
                   end

        handle_response(response)
      end
    end
  end

  def handle_response(response)
    code = response.code

    # 5xx Server Errors are treated as transient network issues
    if code >= 500
      raise HTTParty::Error, "Binance Server Error (#{code}): #{response.body}"
    elsif code >= 400
      # 4xx Client Errors are logged as fatal API errors
      @logger.error("API Client Error (#{code}): #{response.body}")
      exit(1)
    end

    JSON.parse(response.body)
  end

  def with_network_retry
    yield
  rescue HTTParty::Error, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET,
         Errno::ETIMEDOUT, Timeout::Error, OpenSSL::SSL::SSLError => e
    @logger.error("Network connection issue: #{e.message}. Retrying in #{NETWORK_RETRY_DELAY} seconds...")
    sleep NETWORK_RETRY_DELAY
    retry
  end

  # ============================================================================
  # PRECISION & MATH HELPERS
  # ============================================================================
  def fetch_symbol_precisions
    info = send_request(:get, '/api/v3/exchangeInfo')
    symbol_info = info['symbols']&.find { |s| s['symbol'] == SYMBOL }

    if symbol_info
      price_filter = symbol_info['filters']&.find { |f| f['filterType'] == 'PRICE_FILTER' }
      lot_size = symbol_info['filters']&.find { |f| f['filterType'] == 'LOT_SIZE' }

      @price_precision = step_to_precision(price_filter['tickSize']) if price_filter
      @quantity_precision = step_to_precision(lot_size['stepSize']) if lot_size
    end

    @logger.info("Precision initialized: Price=#{@price_precision} decimals, Quantity=#{@quantity_precision} decimals")
  end

  def step_to_precision(step_str)
    return 0 unless step_str.include?('.')
    step_str.split('.').last.index('1') ? step_str.split('.').last.index('1') + 1 : 0
  end

  def floor_to_precision(val, precision)
    factor = 10.0**precision
    ((val.to_f * factor).floor / factor).to_s
  end

  # ============================================================================
  # TRADING CYCLE
  # ============================================================================
  def execute_cycle
    # 1. Buy Execution
    executed_buy_price = execute_buy_phase
    return unless executed_buy_price # Skip cycle if funds were insufficient

    # 2. Sell Execution
    execute_sell_phase(executed_buy_price)
  end

  # --- BUY PHASE ---
  def execute_buy_phase
    fiat_balance = fetch_balance(QUOTE_ASSET)
    current_price = fetch_current_price

    # Check for minimum required funds to proceed
    min_notional = 10.0 # BRL minimum trade threshold
    if fiat_balance < min_notional
      @logger.info("Insufficient #{QUOTE_ASSET} funds (Available: #{fiat_balance}). Skipping cycle...")
      sleep 10
      return nil
    end

    target_price = current_price * (1.0 - BUY_DISCOUNT_PCT)
    quantity = fiat_balance / target_price

    active_order = place_order(
      side: 'BUY',
      price: target_price,
      quantity: quantity
    )

    order_start_time = Time.now.to_i

    loop do
      sleep POLL_INTERVAL
      order_data = fetch_order_status(active_order['orderId'])
      log_order_status_change(order_data)

      status = order_data['status']
      return calculate_executed_price(order_data) if status == 'FILLED'

      # If timeout (1 hour), update price to current market price
      if Time.now.to_i - order_start_time >= ORDER_TIMEOUT_SECONDS
        @logger.info("Buy order #{active_order['orderId']} expired after 1 hour. Replacing order at current price...")
        cancel_order(active_order['orderId'])

        new_price = fetch_current_price
        fiat_balance = fetch_balance(QUOTE_ASSET)
        new_quantity = fiat_balance / new_price

        active_order = place_order(
          side: 'BUY',
          price: new_price,
          quantity: new_quantity
        )
        order_start_time = Time.now.to_i
      end
    end
  end

  # --- SELL PHASE ---
  def execute_sell_phase(buy_price)
    crypto_balance = fetch_balance(BASE_ASSET)

    if crypto_balance <= 0.0001
      @logger.info("Insufficient #{BASE_ASSET} balance to sell. Retrying balance check...")
      sleep 10
      crypto_balance = fetch_balance(BASE_ASSET)
    end

    target_price = buy_price * (1.0 + SELL_PROFIT_PCT)

    active_order = place_order(
      side: 'SELL',
      price: target_price,
      quantity: crypto_balance
    )

    order_start_time = Time.now.to_i

    loop do
      sleep POLL_INTERVAL
      order_data = fetch_order_status(active_order['orderId'])
      log_order_status_change(order_data)

      status = order_data['status']
      return true if status == 'FILLED'

      # If timeout (1 hour), update price to current_price - 0.236%
      if Time.now.to_i - order_start_time >= ORDER_TIMEOUT_SECONDS
        @logger.info("Sell order #{active_order['orderId']} expired after 1 hour. Replacing order...")
        cancel_order(active_order['orderId'])

        curr_price = fetch_current_price
        new_price = curr_price * (1.0 - SELL_PROFIT_PCT)
        crypto_balance = fetch_balance(BASE_ASSET)

        active_order = place_order(
          side: 'SELL',
          price: new_price,
          quantity: crypto_balance
        )
        order_start_time = Time.now.to_i
      end
    end
  end

  # ============================================================================
  # BINANCE API WRAPPERS
  # ============================================================================
  def fetch_current_price
    res = send_request(:get, '/api/v3/ticker/price', { symbol: SYMBOL })
    res['price'].to_f
  end

  def fetch_balance(asset)
    res = send_request(:get, '/api/v3/account', {}, is_private: true)
    balances = res['balances'] || []
    asset_data = balances.find { |b| b['asset'] == asset }
    asset_data ? asset_data['free'].to_f : 0.0
  end

  def place_order(side:, price:, quantity:)
    formatted_price = floor_to_precision(price, @price_precision)
    formatted_qty   = floor_to_precision(quantity, @quantity_precision)

    params = {
      symbol: SYMBOL,
      side: side,
      type: 'LIMIT',
      timeInForce: 'GTC',
      quantity: formatted_qty,
      price: formatted_price
    }

    res = send_request(:post, '/api/v3/order', params, is_private: true)
    log_order_status_change(res)
    res
  end

  def cancel_order(order_id)
    send_request(:delete, '/api/v3/order', { symbol: SYMBOL, orderId: order_id }, is_private: true)
  rescue StandardError => e
    @logger.warn("Failed to cancel order #{order_id}: #{e.message}")
  end

  def fetch_order_status(order_id)
    send_request(:get, '/api/v3/order', { symbol: SYMBOL, orderId: order_id }, is_private: true)
  end

  def calculate_executed_price(order_data)
    cummulative_quote = order_data['cummulativeQuoteQty'].to_f
    executed_qty = order_data['executedQty'].to_f
    return order_data['price'].to_f if executed_qty.zero?

    cummulative_quote / executed_qty
  end

  def log_order_status_change(order)
    order_id = order['orderId']
    status   = order['status']

    return if @last_logged_statuses[order_id] == status

    @last_logged_statuses[order_id] = status
    @logger.info("ORDER UPDATE | ID: #{order_id} | Type: #{order['type']} | Side: #{order['side']} | " \
                 "Symbol: #{order['symbol']} | Price: #{order['price']} | Qty: #{order['origQty']} | Status: #{status}")
  end
end

# Ensure graceful log on process termination
at_exit do
  logger = Logger.new(LOG_FILE, datetime_format: '%Y-%m-%d %H:%M:%S')
  logger.info("Script execution ending.")
end

# Run the Bot
ScavengerTrader.new.run
