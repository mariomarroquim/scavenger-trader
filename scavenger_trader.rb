#!/usr/bin/env ruby
# AI LLM Model: Gemini 1.5 Pro

require 'httparty'
require 'openssl'
require 'logger'
require 'json'
require 'bigdecimal'
require 'bigdecimal/util'
require 'uri'
require 'thread'

# ==========================================
# SETTINGS & GLOBAL CONSTANTS
# ==========================================
LLM_MODEL              = 'Gemini 1.5 Pro'.freeze
SYMBOL                 = 'ETHBRL'.freeze
BASE_ASSET             = 'ETH'.freeze
QUOTE_ASSET            = 'BRL'.freeze
TAKE_PROFIT_MULTIPLIER = BigDecimal('1.00236')
STOP_LOSS_MULTIPLIER   = BigDecimal('1.00175')
SELL_TIMEOUT_SECONDS   = 5 * 3600
NETWORK_RETRY_INTERVAL = 300
NETWORK_MAX_RETRY_TIME = 5 * 3600

API_KEY                = ENV['BINANCE_API_KEY']
API_SECRET             = ENV['BINANCE_API_SECRET']
API_BASE_URL           = 'https://api.binance.com'.freeze

# ==========================================
# LOGGER SETUP
# ==========================================
# Logs strictly to a file with time prefix, no STDOUT
LOGGER = Logger.new('scavenger_trader.log', 'monthly')
LOGGER.formatter = proc do |severity, datetime, progname, msg|
  "#{datetime.strftime('%Y-%m-%d %H:%M:%S')} [#{severity}] #{msg}\n"
end

# ==========================================
# CORE ERROR HANDLING & RATE LIMITING
# ==========================================
class APIError < StandardError; end

NETWORK_ERRORS = [
  SocketError,
  Timeout::Error,
  SystemCallError,
  OpenSSL::SSL::SSLError,
  EOFError,
  Net::ProtocolError,
  Zlib::DataError,
  Zlib::BufError,
  JSON::ParserError
].freeze

module RateLimiter
  @last_request_time = Time.at(0)
  @mutex = Mutex.new

  # Limits to exactly 1 request per second
  def self.wait
    @mutex.synchronize do
      now = Time.now
      elapsed = now - @last_request_time
      sleep(1.0 - elapsed) if elapsed < 1.0
      @last_request_time = Time.now
    end
  end
end

module Binance
  def self.request(method, endpoint, params = {})
    RateLimiter.wait

    headers = { 'X-MBX-APIKEY' => API_KEY }
    params.reject! { |_, v| v.nil? }

    if [:post, :delete, :put, :signed_get].include?(method)
      params[:timestamp] = (Time.now.to_f * 1000).to_i
      query_string = URI.encode_www_form(params)
      signature = OpenSSL::HMAC.hexdigest('SHA256', API_SECRET, query_string)
      params[:signature] = signature
      query_string = URI.encode_www_form(params) # Re-encode including signature
      http_method = method == :signed_get ? :get : method
    else
      query_string = URI.encode_www_form(params)
      http_method = method
    end

    url = "#{API_BASE_URL}#{endpoint}?#{query_string}"
    response = HTTParty.send(http_method, url, headers: headers)

    begin
      parsed = JSON.parse(response.body)
    rescue JSON::ParserError
      raise JSON::ParserError, "Failed to parse Binance response (Gateway issue?): #{response.body[0..100]}..."
    end

    if response.code != 200
      raise APIError, "Binance API Error (Code: #{response.code}): #{parsed['msg'] || parsed}"
    end

    parsed
  end
end

def api_call
  start_time = Time.now
  begin
    yield
  rescue *NETWORK_ERRORS => e
    elapsed = Time.now - start_time
    if elapsed > NETWORK_MAX_RETRY_TIME
      LOGGER.fatal("Network retry timeout reached (5 hours). Error: #{e.message}. Exiting.")
      exit(1)
    end
    LOGGER.warn("Network error: #{e.class} - #{e.message}. Retrying in 5 minutes...")
    sleep NETWORK_RETRY_INTERVAL
    retry
  rescue APIError, StandardError => e
    LOGGER.fatal("Fatal error: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}. Exiting.")
    exit(1)
  end
end

# ==========================================
# ORDER POLLING LOGIC
# ==========================================
def wait_for_order(order_id, timeout_seconds = nil)
  start_time = Time.now
  last_status = nil

  loop do
    order = api_call { Binance.request(:signed_get, '/api/v3/order', { symbol: SYMBOL, orderId: order_id }) }
    status = order['status']

    if status != last_status
      LOGGER.info("Order Status Update: ID=#{order_id} | Status=#{status} | Type=#{order['type']} | Side=#{order['side']} | Symbol=#{order['symbol']} | Price=#{order['price']} | Qty=#{order['origQty']} | Executed=#{order['executedQty']}")
      last_status = status
    end

    return order if %w[FILLED CANCELED REJECTED EXPIRED EXPIRED_IN_MATCH].include?(status)

    if timeout_seconds && (Time.now - start_time) > timeout_seconds
      LOGGER.info("Order ID=#{order_id} reached timeout of #{timeout_seconds}s. Cancelling...")
      begin
        api_call { Binance.request(:delete, '/api/v3/order', { symbol: SYMBOL, orderId: order_id }) }
      rescue APIError => e
        LOGGER.warn("Failed to cancel timeout order (may have already filled): #{e.message}")
      end
      # Fetch final state to guarantee we return the definitive status
      return api_call { Binance.request(:signed_get, '/api/v3/order', { symbol: SYMBOL, orderId: order_id }) }
    end

    sleep 5 # Poll gently to save API limits
  end
end

# ==========================================
# MAIN EXECUTION LOOP
# ==========================================
if API_KEY.nil? || API_KEY.empty? || API_SECRET.nil? || API_SECRET.empty?
  LOGGER.fatal("Missing BINANCE_API_KEY or BINANCE_API_SECRET environment variables. Exiting.")
  exit(1)
end

LOGGER.info("Scavenger Trader started. Powered by #{LLM_MODEL}")
at_exit { LOGGER.info("Scavenger Trader ended.") }
out_of_funds_logged = false

loop do
  # 1. Fetch live exchange precision data
  info = api_call { Binance.request(:get, '/api/v3/exchangeInfo', { symbol: SYMBOL }) }
  symbol_info = info['symbols'].find { |s| s['symbol'] == SYMBOL }

  tick_size = BigDecimal(symbol_info['filters'].find { |f| f['filterType'] == 'PRICE_FILTER' }['tickSize'])
  step_size = BigDecimal(symbol_info['filters'].find { |f| f['filterType'] == 'LOT_SIZE' }['stepSize'])
  min_notional = BigDecimal(symbol_info['filters'].find { |f| f['filterType'] == 'NOTIONAL' }['minNotional'])

  # 2. Check BRL Balance and Market Buy
  account = api_call { Binance.request(:signed_get, '/api/v3/account') }
  brl_asset = account['balances'].find { |b| b['asset'] == QUOTE_ASSET }
  brl_balance = brl_asset ? BigDecimal(brl_asset['free']) : BigDecimal('0')

  buy_qty = (brl_balance / tick_size).floor * tick_size # Format to quote precision

  if buy_qty < min_notional
    unless out_of_funds_logged
      LOGGER.info("Insufficient #{QUOTE_ASSET} balance. Skipping cycle until funds are available.")
      out_of_funds_logged = true
    end
    sleep 10
    next
  else
    out_of_funds_logged = false
  end

  buy_params = {
    symbol: SYMBOL,
    side: 'BUY',
    type: 'MARKET',
    quoteOrderQty: buy_qty.to_s('F')
  }

  buy_order = api_call { Binance.request(:post, '/api/v3/order', buy_params) }
  filled_buy = wait_for_order(buy_order['orderId'])

  if filled_buy['status'] != 'FILLED'
    LOGGER.warn("Buy order failed to fill. Final status: #{filled_buy['status']}. Restarting cycle.")
    sleep 5
    next
  end

  cumm_quote_qty = BigDecimal(filled_buy['cummulativeQuoteQty'])
  executed_qty = BigDecimal(filled_buy['executedQty'])

  if executed_qty.zero?
    LOGGER.warn("Executed quantity is 0. Restarting cycle.")
    sleep 5
    next
  end

  avg_buy_price = cumm_quote_qty / executed_qty

  # 3. Take Profit Limit Sell
  account = api_call { Binance.request(:signed_get, '/api/v3/account') }
  eth_asset = account['balances'].find { |b| b['asset'] == BASE_ASSET }
  eth_balance = eth_asset ? BigDecimal(eth_asset['free']) : BigDecimal('0')

  sell_qty = (eth_balance / step_size).floor * step_size
  take_profit_price = (avg_buy_price * TAKE_PROFIT_MULTIPLIER / tick_size).floor * tick_size

  if (sell_qty * take_profit_price) < min_notional
    LOGGER.warn("Sell order notional value too small. Needs manual review. Skipping.")
    sleep 60
    next
  end

  sell_params = {
    symbol: SYMBOL,
    side: 'SELL',
    type: 'LIMIT',
    timeInForce: 'GTC',
    quantity: sell_qty.to_s('F'),
    price: take_profit_price.to_s('F')
  }

  sell_order = api_call { Binance.request(:post, '/api/v3/order', sell_params) }
  final_sell = wait_for_order(sell_order['orderId'], SELL_TIMEOUT_SECONDS)

  # 4. Fallback Logic (Stop Loss / Reprice) if timeout reached
  if final_sell['status'] == 'CANCELED'
    # Refresh balances in case of partial fills during the 5 hour window
    account = api_call { Binance.request(:signed_get, '/api/v3/account') }
    eth_asset = account['balances'].find { |b| b['asset'] == BASE_ASSET }
    eth_balance = eth_asset ? BigDecimal(eth_asset['free']) : BigDecimal('0')

    remaining_qty = (eth_balance / step_size).floor * step_size
    stop_loss_price = (avg_buy_price * STOP_LOSS_MULTIPLIER / tick_size).floor * tick_size

    if (remaining_qty * stop_loss_price) >= min_notional
      fallback_params = {
        symbol: SYMBOL,
        side: 'SELL',
        type: 'LIMIT',
        timeInForce: 'GTC',
        quantity: remaining_qty.to_s('F'),
        price: stop_loss_price.to_s('F')
      }

      fallback_order = api_call { Binance.request(:post, '/api/v3/order', fallback_params) }
      # Wait indefinitely for the stop loss fallback to fill
      wait_for_order(fallback_order['orderId'])
    else
      LOGGER.warn("Remaining quantity after cancellation is below min notional limit. Skipping fallback.")
    end
  elsif final_sell['status'] != 'FILLED'
    LOGGER.warn("Sell order ended in unexpected terminal status: #{final_sell['status']}.")
  end
end
