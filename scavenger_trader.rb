#!/usr/bin/env ruby
# frozen_string_literal: true

require 'httparty'
require 'json'
require 'openssl'
require 'logger'
require 'bigdecimal'
require 'bigdecimal/util'

# --- GLOBAL CONSTANTS ---
API_KEY = ENV['BINANCE_API_KEY']
API_SECRET = ENV['BINANCE_API_SECRET']

SYMBOL = 'ETHBRL'
BASE_ASSET = 'ETH'
QUOTE_ASSET = 'BRL'

PROFIT_MULTIPLIER_1 = BigDecimal('1.00236') # +0.236%
PROFIT_MULTIPLIER_2 = BigDecimal('1.00175') # +0.175%

TIMEOUT_5_HOURS = 5 * 60 * 60
NETWORK_RETRY_DELAY = 5 * 60
MAX_NETWORK_RETRIES = 60

BASE_URL = 'https://api.binance.com'
LLM_MODEL = 'Gemini 1.5 Pro'

# Network-related exceptions to retry
NETWORK_ERRORS = [
  SocketError,
  Timeout::Error,
  Errno::ECONNREFUSED,
  Errno::EHOSTUNREACH,
  Errno::ECONNRESET,
  Net::OpenTimeout,
  Net::ReadTimeout,
  EOFError
].freeze

# Configure Logger (File only, No STDOUT)
LOGGER = Logger.new('scavenger_trader.log')
LOGGER.formatter = proc do |severity, datetime, _progname, msg|
  "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{severity}: #{msg}\n"
end

class ScavengerTrader
  def initialize
    @tick_size = nil
    @step_size = nil
    @min_notional = nil
    @quote_precision = nil
  end

  def run
    LOGGER.info("Starting Scavenger Trader script. AI Model: #{LLM_MODEL}")

    if API_KEY.nil? || API_KEY.empty? || API_SECRET.nil? || API_SECRET.empty?
      raise StandardError, 'Missing BINANCE_API_KEY or BINANCE_API_SECRET environment variables'
    end

    fetch_exchange_info

    loop do
      brl_balance = get_free_balance(QUOTE_ASSET)

      if brl_balance < @min_notional
        # Skip cycle if no available funds. Small delay prevents extreme hot-looping.
        sleep 10
        next
      end

      # 1. Market Buy
      buy_order = place_market_buy(brl_balance)
      buy_order_info = wait_for_order(buy_order['orderId'])

      if buy_order_info['status'] != 'FILLED'
        LOGGER.warn("Buy order #{buy_order['orderId']} status is #{buy_order_info['status']}. Retrying cycle...")
        sleep 5
        next
      end

      executed_qty = BigDecimal(buy_order_info['executedQty'])
      cummulative_quote_qty = BigDecimal(buy_order_info['cummulativeQuoteQty'])

      if executed_qty.zero?
        LOGGER.error('Buy order executed qty is 0. Retrying cycle...')
        sleep 5
        next
      end

      avg_buy_price = cummulative_quote_qty / executed_qty

      # 2. Limit Sell (Initial Profit Target)
      eth_balance = get_free_balance(BASE_ASSET)
      sell_qty = round_down(eth_balance, @step_size)
      sell_price = round_down(avg_buy_price * PROFIT_MULTIPLIER_1, @tick_size)

      if BigDecimal(sell_qty) <= BigDecimal('0') || (BigDecimal(sell_qty) * BigDecimal(sell_price)) < @min_notional
        LOGGER.warn('Insufficient ETH balance or notional value to place sell order. Skipping cycle...')
        sleep 10
        next
      end

      sell_order = place_limit_sell(sell_qty, sell_price)
      sell_order_info = wait_for_order(sell_order['orderId'], TIMEOUT_5_HOURS)

      # 3. Handle 5-Hour Timeout (Adjust Profit Target)
      if !['FILLED', 'CANCELED', 'REJECTED', 'EXPIRED'].include?(sell_order_info['status'])
        cancel_order(sell_order['orderId'])
        sleep 2 # Brief pause to allow exchange state to settle

        new_sell_price = round_down(avg_buy_price * PROFIT_MULTIPLIER_2, @tick_size)
        eth_balance = get_free_balance(BASE_ASSET) # Re-check balance (handles partial fills properly)
        new_sell_qty = round_down(eth_balance, @step_size)

        if BigDecimal(new_sell_qty) > BigDecimal('0') && (BigDecimal(new_sell_qty) * BigDecimal(new_sell_price)) >= @min_notional
          new_sell_order = place_limit_sell(new_sell_qty, new_sell_price)
          wait_for_order(new_sell_order['orderId']) # Wait indefinitely
        end
      end
    end
  rescue StandardError => e
    LOGGER.fatal("Script aborted: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}")
    exit(1)
  ensure
    LOGGER.info('Scavenger Trader script ended.')
  end

  private

  # Wraps all HTTParty requests to Binance, enforcing rate limits and managing retries
  def api_request(method, endpoint, params = {}, signed = false)
    retries = 0

    begin
      sleep 1 # Global API constraint: Max 1 request per second

      headers = {}
      headers['X-MBX-APIKEY'] = API_KEY if API_KEY

      query = params.dup
      if signed
        query[:timestamp] = (Time.now.to_f * 1000).to_i
        query_string = URI.encode_www_form(query)
        query[:signature] = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), API_SECRET, query_string)
      end

      url = "#{BASE_URL}#{endpoint}"
      response = HTTParty.send(method, url, query: query, headers: headers)
      parsed_response = JSON.parse(response.body)

      unless response.success?
        raise StandardError, "Binance API Error: #{parsed_response['code']} - #{parsed_response['msg']}"
      end

      parsed_response
    rescue *NETWORK_ERRORS => e
      if retries < MAX_NETWORK_RETRIES
        retries += 1
        LOGGER.warn("Network error (#{e.class}: #{e.message}), retrying #{retries}/#{MAX_NETWORK_RETRIES} in #{NETWORK_RETRY_DELAY} seconds...")
        sleep NETWORK_RETRY_DELAY
        retry
      else
        raise e
      end
    end
  end

  # Fetch Binance precision rules dynamically to strictly adhere to asset math constraints
  def fetch_exchange_info
    info = api_request(:get, '/api/v3/exchangeInfo', { symbol: SYMBOL })
    symbol_info = info['symbols'].first

    price_filter = symbol_info['filters'].find { |f| f['filterType'] == 'PRICE_FILTER' }
    lot_size = symbol_info['filters'].find { |f| f['filterType'] == 'LOT_SIZE' }
    notional = symbol_info['filters'].find { |f| f['filterType'] == 'NOTIONAL' }

    @tick_size = BigDecimal(price_filter['tickSize'])
    @step_size = BigDecimal(lot_size['stepSize'])
    @min_notional = BigDecimal(notional['minNotional'])
    @quote_precision = symbol_info['quoteAssetPrecision']
  end

  def get_free_balance(asset)
    account = api_request(:get, '/api/v3/account', {}, true)
    balance = account['balances'].find { |b| b['asset'] == asset }
    balance ? BigDecimal(balance['free']) : BigDecimal('0')
  end

  def place_market_buy(quote_amount)
    qty = round_down_precision(quote_amount, @quote_precision)
    api_request(:post, '/api/v3/order', {
      symbol: SYMBOL,
      side: 'BUY',
      type: 'MARKET',
      quoteOrderQty: qty
    }, true)
  end

  def place_limit_sell(qty, price)
    api_request(:post, '/api/v3/order', {
      symbol: SYMBOL,
      side: 'SELL',
      type: 'LIMIT',
      timeInForce: 'GTC',
      quantity: qty,
      price: price
    }, true)
  end

  def cancel_order(order_id)
    api_request(:delete, '/api/v3/order', { symbol: SYMBOL, orderId: order_id }, true)
  end

  # Polls an order until final status or timeout. Logs exactly once per status update.
  def wait_for_order(order_id, timeout = nil)
    start_time = Time.now
    last_status = nil

    loop do
      order_info = api_request(:get, '/api/v3/order', { symbol: SYMBOL, orderId: order_id }, true)
      current_status = order_info['status']

      if current_status != last_status
        LOGGER.info(
          "Order #{order_id} status changed to #{current_status} | " \
          "Type: #{order_info['type']}, Side: #{order_info['side']}, Symbol: #{order_info['symbol']}, " \
          "Price: #{order_info['price']}, Qty: #{order_info['origQty']}"
        )
        last_status = current_status
      end

      return order_info if ['FILLED', 'CANCELED', 'REJECTED', 'EXPIRED'].include?(current_status)

      if timeout && (Time.now - start_time) > timeout
        return order_info
      end

      # sleep is omitted here because api_request automatically ensures 1 request per second
    end
  end

  # --- MATH HELPERS ---

  # Floor a value to the nearest step increment mathematically (for lot/tick size filters)
  def round_down(value, step)
    val = BigDecimal(value.to_s)
    step_bd = BigDecimal(step.to_s)
    ((val / step_bd).floor * step_bd).to_s('F')
  end

  # Direct decimal truncation based on asset base precision integer
  def round_down_precision(value, precision)
    val = BigDecimal(value.to_s)
    val.truncate(precision).to_s('F')
  end
end

# Kick off the bot script
ScavengerTrader.new.run
