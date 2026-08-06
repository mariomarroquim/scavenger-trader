#!/usr/bin/env ruby
# frozen_string_literal: true

require 'httparty'
require 'openssl'
require 'json'
require 'logger'
require 'bigdecimal'
require 'bigdecimal/util'

# ==============================================================================
# Configuration & Constants
# ==============================================================================
AI_LLM_MODEL          = 'Gemini 2.5 Flash'
AI_LLM_VERSION        = '2026.08'

SYMBOL                = 'ETHBRL'
BASE_ASSET            = 'ETH'
QUOTE_ASSET           = 'BRL'

PROFIT_MARGIN         = 0.00382  # 0.382% target profit
PRICE_ADJUSTMENT      = 0.00175  # 0.175% price bump on timeout
TIMEOUT_HOURS         = 1
SELL_TIMEOUT_SECONDS  = TIMEOUT_HOURS * 3600

RATE_LIMIT_INTERVAL   = 1.0      # Min seconds between API calls (1 req/sec)
NETWORK_RETRY_DELAY   = 60       # Seconds to wait after network errors
POLL_INTERVAL         = 5        # Seconds between order status checks

BASE_URL              = 'https://api.binance.com'
LOG_FILE              = 'scavenger_trader.log'

# ==============================================================================
# Logger Setup
# ==============================================================================
class FileOnlyLogger < Logger
  def initialize(log_dev)
    super(log_dev)
    self.formatter = proc do |severity, datetime, _progname, msg|
      "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] [#{severity}] #{msg}\n"
    end
  end
end

LOGGER = FileOnlyLogger.new(LOG_FILE)

# ==============================================================================
# Binance REST API Client
# ==============================================================================
class BinanceClient
  include HTTParty
  base_uri BASE_URL

  def initialize(api_key, api_secret)
    @api_key = api_key
    @api_secret = api_secret
    @last_request_time = Time.now - RATE_LIMIT_INTERVAL
  end

  def exchange_info(symbol)
    public_request(:get, '/api/v3/exchangeInfo', query: { symbol: symbol })
  end

  def account_info
    signed_request(:get, '/api/v3/account')
  end

  def create_market_buy_order(symbol, quote_qty)
    params = {
      symbol: symbol,
      side: 'BUY',
      type: 'MARKET',
      quoteOrderQty: quote_qty
    }
    signed_request(:post, '/api/v3/order', body: params)
  end

  def create_limit_sell_order(symbol, quantity, price)
    params = {
      symbol: symbol,
      side: 'SELL',
      type: 'LIMIT',
      timeInForce: 'GTC',
      quantity: quantity,
      price: price
    }
    signed_request(:post, '/api/v3/order', body: params)
  end

  def query_order(symbol, order_id)
    signed_request(:get, '/api/v3/order', query: { symbol: symbol, orderId: order_id })
  end

  def cancel_order(symbol, order_id)
    signed_request(:delete, '/api/v3/order', query: { symbol: symbol, orderId: order_id })
  end

  private

  def enforce_rate_limit
    elapsed = Time.now - @last_request_time
    sleep(RATE_LIMIT_INTERVAL - elapsed) if elapsed < RATE_LIMIT_INTERVAL
    @last_request_time = Time.now
  end

  def public_request(http_method, path, options = {})
    execute_request_with_retry do
      enforce_rate_limit
      response = self.class.send(http_method, path, options)
      parse_response(response)
    end
  end

  def signed_request(http_method, path, options = {})
    execute_request_with_retry do
      enforce_rate_limit

      params = (options[:query] || options[:body] || {}).dup
      params[:timestamp] = (Time.now.to_f * 1000).to_i

      query_string = URI.encode_www_form(params)
      signature = OpenSSL::HMAC.hexdigest('sha256', @api_secret, query_string)
      params[:signature] = signature

      headers = { 'X-MBX-APIKEY' => @api_key }

      req_options = { headers: headers }
      if http_method == :get || http_method == :delete
        req_options[:query] = params
      else
        req_options[:body] = params
      end

      response = self.class.send(http_method, path, req_options)
      parse_response(response)
    end
  end

  def execute_request_with_retry
    yield
  rescue HTTParty::Error, SocketError, Errno::ECONNREFUSED, Errno::ETIMEDOUT, Timeout::Error, OpenSSL::SSL::SSLError => e
    LOGGER.warn("Network error encountered: #{e.message}. Retrying in #{NETWORK_RETRY_DELAY}s...")
    sleep NETWORK_RETRY_DELAY
    retry
  end

  def parse_response(response)
    json = JSON.parse(response.body)
    unless response.success?
      code = json['code'] || response.code
      msg = json['msg'] || response.message
      raise StandardError, "API Error [#{code}]: #{msg}"
    end
    json
  end
end

# ==============================================================================
# Main Bot Engine
# ==============================================================================
class ScavengerTrader
  def initialize
    @api_key = ENV['BINANCE_API_KEY']
    @api_secret = ENV['BINANCE_API_SECRET']

    if @api_key.nil? || @api_key.empty? || @api_secret.nil? || @api_secret.empty?
      LOGGER.error('Missing BINANCE_API_KEY or BINANCE_API_SECRET environment variables.')
      exit 1
    end

    @client = BinanceClient.new(@api_key, @api_secret)
    @tracked_orders = {}
  end

  def start
    LOGGER.info("Starting Scavenger Trader Script (AI Model: #{AI_LLM_MODEL} v#{AI_LLM_VERSION})")
    load_symbol_rules

    loop do
      execute_trading_cycle
    end
  rescue Interrupt
    LOGGER.info('Execution interrupted by user.')
  rescue StandardError => e
    LOGGER.error("Fatal error: #{e.message}\n#{e.backtrace.join("\n")}")
  ensure
    LOGGER.info('Scavenger Trader Script execution ended.')
  end

  private

  def load_symbol_rules
    info = @client.exchange_info(SYMBOL)
    symbol_data = info['symbols'].find { |s| s['symbol'] == SYMBOL }

    price_filter = symbol_data['filters'].find { |f| f['filterType'] == 'PRICE_FILTER' }
    lot_filter = symbol_data['filters'].find { |f| f['filterType'] == 'LOT_SIZE' }
    min_notional_filter = symbol_data['filters'].find { |f| f['filterType'] == 'NOTIONAL' }

    @tick_size = BigDecimal(price_filter['tickSize'])
    @step_size = BigDecimal(lot_filter['stepSize'])
    @min_notional = min_notional_filter ? BigDecimal(min_notional_filter['minNotional']) : BigDecimal('10.0')

    LOGGER.info("Symbol rules loaded for #{SYMBOL}: tickSize=#{@tick_size.to_s('F')}, stepSize=#{@step_size.to_s('F')}")
  end

  def execute_trading_cycle
    # --------------------------------------------------------------------------
    # 1. Buy Phase
    # --------------------------------------------------------------------------
    fiat_balance = get_balance(QUOTE_ASSET)

    if fiat_balance < @min_notional
      LOGGER.info("Insufficient #{QUOTE_ASSET} balance (#{fiat_balance.to_s('F')} < min #{@min_notional.to_s('F')}). Skipping cycle.")
      sleep POLL_INTERVAL
      return
    end

    LOGGER.info("Placing MARKET BUY for full available balance: #{fiat_balance.to_s('F')} #{QUOTE_ASSET}")
    buy_response = @client.create_market_buy_order(SYMBOL, round_down_str(fiat_balance, @tick_size))
    buy_order_id = buy_response['orderId']

    buy_order = wait_for_order_fill(buy_order_id)
    executed_qty = BigDecimal(buy_order['executedQty'])
    cummulative_quote_qty = BigDecimal(buy_order['cummulativeQuoteQty'])

    if executed_qty.zero?
      LOGGER.error('Buy order filled with 0 quantity. Exiting loop.')
      raise StandardError, 'Market buy returned 0 executed quantity.'
    end

    avg_buy_price = cummulative_quote_qty / executed_qty
    LOGGER.info("Buy order filled. Executed Qty: #{executed_qty.to_s('F')} #{BASE_ASSET}, Avg Price: #{avg_buy_price.to_s('F')} #{QUOTE_ASSET}")

    # --------------------------------------------------------------------------
    # 2. Sell Phase
    # --------------------------------------------------------------------------
    target_sell_price = avg_buy_price * (BigDecimal('1') + BigDecimal(PROFIT_MARGIN.to_s))
    crypto_balance = get_balance(BASE_ASSET)

    if crypto_balance < @step_size
      LOGGER.error("Insufficient crypto balance to place sell order: #{crypto_balance.to_s('F')} #{BASE_ASSET}")
      raise StandardError, 'Insufficient crypto balance after buy execution.'
    end

    sell_qty = round_down(crypto_balance, @step_size)
    current_sell_price = round_down(target_sell_price, @tick_size)

    LOGGER.info("Placing LIMIT SELL: Qty=#{sell_qty.to_s('F')}, Price=#{current_sell_price.to_s('F')}")
    sell_response = @client.create_limit_sell_order(SYMBOL, sell_qty.to_s('F'), current_sell_price.to_s('F'))
    sell_order_id = sell_response['orderId']
    log_order_status_change(sell_response)

    sell_order_start_time = Time.now

    loop do
      sleep POLL_INTERVAL
      sell_order = @client.query_order(SYMBOL, sell_order_id)
      log_order_status_change(sell_order)

      break if sell_order['status'] == 'FILLED'

      if sell_order['status'] == 'CANCELED' || sell_order['status'] == 'REJECTED'
        raise StandardError, "Sell order was prematurely #{sell_order['status']}"
      end

      # Timeout Check (1 hour)
      next unless Time.now - sell_order_start_time >= SELL_TIMEOUT_SECONDS

      LOGGER.info("Sell order #{sell_order_id} timed out after #{TIMEOUT_HOURS}h. Adjusting price...")
      @client.cancel_order(SYMBOL, sell_order_id)

      # Wait briefly and update price
      target_sell_price = current_sell_price * (BigDecimal('1') + BigDecimal(PRICE_ADJUSTMENT.to_s))
      current_sell_price = round_down(target_sell_price, @tick_size)

      # Ensure available balance for new sell order
      crypto_balance = get_balance(BASE_ASSET)
      sell_qty = round_down(crypto_balance, @step_size)

      LOGGER.info("Re-placing LIMIT SELL: Qty=#{sell_qty.to_s('F')}, Price=#{current_sell_price.to_s('F')}")
      sell_response = @client.create_limit_sell_order(SYMBOL, sell_qty.to_s('F'), current_sell_price.to_s('F'))
      sell_order_id = sell_response['orderId']
      log_order_status_change(sell_response)

      sell_order_start_time = Time.now
    end

    LOGGER.info("Sell cycle complete. Cycle restart.\n#{'-' * 60}")
  end

  def wait_for_order_fill(order_id)
    loop do
      order = @client.query_order(SYMBOL, order_id)
      log_order_status_change(order)
      return order if order['status'] == 'FILLED'

      sleep POLL_INTERVAL
    end
  end

  def get_balance(asset)
    acc = @client.account_info
    balance = acc['balances'].find { |b| b['asset'] == asset }
    balance ? BigDecimal(balance['free']) : BigDecimal('0')
  end

  def log_order_status_change(order)
    order_id = order['orderId']
    status = order['status']

    if @tracked_orders[order_id] != status
      @tracked_orders[order_id] = status
      price = order['price'].to_f.zero? ? order['cummulativeQuoteQty'] : order['price']
      LOGGER.info("ORDER UPDATE | ID: #{order_id} | Side: #{order['side']} | Type: #{order['type']} | " \
                  "Symbol: #{order['symbol']} | Status: #{status} | Price: #{price} | Qty: #{order['origQty']}")
    end
  end

  def round_down(value, step_size)
    return value if step_size.nil? || step_size.zero?

    precision = -Math.log10(step_size.to_f).round
    if precision <= 0
      (value / step_size).floor * step_size
    else
      value.floor(precision)
    end
  end

  def round_down_str(value, step_size)
    round_down(value, step_size).to_s('F')
  end
end

# ==============================================================================
# Script Execution
# ==============================================================================
ScavengerTrader.new.start if __FILE__ == $PROGRAM_NAME
