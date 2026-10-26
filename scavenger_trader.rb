#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bigdecimal'
require 'bigdecimal/util'
require 'httparty'
require 'json'
require 'logger'
require 'openssl'
require 'uri'

# ============================================================================
# Settings
# ============================================================================
LLM_MODEL = 'Claude Opus 5.5'

API_BASE_URL = 'https://api.binance.com'
API_KEY = ENV['BINANCE_API_KEY']
API_SECRET = ENV['BINANCE_API_SECRET']
API_RECV_WINDOW = 5_000

SYMBOL = 'ETHBRL'
BASE_ASSET = 'ETH'
QUOTE_ASSET = 'BRL'

BUY_DISCOUNT_RATE = BigDecimal('0.99925')
TAKE_PROFIT_RATE = BigDecimal('1.00225')
FALLBACK_PROFIT_RATE = BigDecimal('1.0015')
TAKE_PROFIT_TIMEOUT = 60 * 60
FALLBACK_PROFIT_TIMEOUT = 60 * 60

REQUEST_INTERVAL = 1
ORDER_POLL_INTERVAL = 5
NO_FUNDS_INTERVAL = 60
NETWORK_RETRY_INTERVAL = 5 * 60
NETWORK_RETRY_TIMEOUT = 60 * 60

LOG_FILE = 'scavenger_trader.log'

LOGGER = Logger.new(LOG_FILE)
LOGGER.formatter = proc do |severity, time, _program, message|
  "#{time.strftime('%Y-%m-%d %H:%M:%S')} [#{severity}] #{message}\n"
end

# ============================================================================
# Binance REST API client
# ============================================================================

# Raised when Binance answers with an error payload that will not fix itself.
class BinanceError < StandardError; end

# Raised for gateway hiccups, clock drift and malformed payloads, which are worth retrying.
class TransientError < StandardError; end

# Raised once the network retry window is exhausted, ending the script.
class NetworkError < StandardError; end

class BinanceClient
  RETRYABLE_ERRORS = [
    EOFError,
    Errno::ECONNREFUSED,
    Errno::ECONNRESET,
    Errno::EHOSTUNREACH,
    Errno::ENETUNREACH,
    Errno::ETIMEDOUT,
    Net::ProtocolError,
    OpenSSL::SSL::SSLError,
    SocketError,
    Timeout::Error,
    TransientError
  ].freeze

  TIMESTAMP_OUTSIDE_RECV_WINDOW = -1021

  def initialize
    @last_request_at = Time.at(0)
    @clock_offset = nil
  end

  def get(endpoint, params = {}) = request(:get, endpoint, params, signed: false)

  def signed_get(endpoint, params = {}) = request(:get, endpoint, params)

  def post(endpoint, params = {}) = request(:post, endpoint, params)

  def delete(endpoint, params = {}) = request(:delete, endpoint, params)

  private

  # Retries transient network failures on a fixed interval, then gives up so the
  # main loop can log the failure and exit.
  def request(method, endpoint, params, signed: true)
    deadline = Time.now + NETWORK_RETRY_TIMEOUT

    begin
      query = signed ? signed_query(params) : URI.encode_www_form(params.compact)
      throttle
      perform(method, "#{API_BASE_URL}#{endpoint}?#{query}")
    rescue *RETRYABLE_ERRORS => error
      raise NetworkError, "#{error.class}: #{error.message}" if Time.now >= deadline

      LOGGER.warn("Network failure (#{error.class}: #{error.message}). Retrying in #{NETWORK_RETRY_INTERVAL}s.")
      sleep NETWORK_RETRY_INTERVAL
      retry
    end
  end

  def perform(method, url)
    response = HTTParty.send(method, url, headers: { 'X-MBX-APIKEY' => API_KEY })

    raise TransientError, "Binance is unavailable (HTTP #{response.code})." if response.code >= 500

    body = parse(response)

    return body if response.code == 200

    # The local clock drifts away from Binance's (notably after the host
    # sleeps), so the offset is measured again before the retry.
    if body['code'] == TIMESTAMP_OUTSIDE_RECV_WINDOW
      @clock_offset = nil
      raise TransientError, "Binance refused the request timestamp: #{body['msg']}"
    end

    raise BinanceError, "Binance refused the request (HTTP #{response.code}): #{body['msg'] || body}."
  end

  def signed_query(params)
    params = params.compact.merge(timestamp:, recvWindow: API_RECV_WINDOW)
    query = URI.encode_www_form(params)
    signature = OpenSSL::HMAC.hexdigest('SHA256', API_SECRET, query)

    "#{query}&signature=#{signature}"
  end

  def timestamp
    @clock_offset ||= server_clock_offset
    current_millis + @clock_offset
  end

  def server_clock_offset
    throttle
    server_time = perform(:get, "#{API_BASE_URL}/api/v3/time")['serverTime']

    server_time - current_millis
  end

  def current_millis = (Time.now.to_f * 1000).to_i

  def parse(response)
    JSON.parse(response.body.to_s)
  rescue JSON::ParserError
    raise TransientError, "Binance returned an unreadable payload (HTTP #{response.code})."
  end

  # Binance throttles aggressively, so requests are spaced out globally.
  def throttle
    elapsed = Time.now - @last_request_at
    sleep(REQUEST_INTERVAL - elapsed) if elapsed < REQUEST_INTERVAL
    @last_request_at = Time.now
  end
end

# ============================================================================
# Trading strategy
# ============================================================================
SymbolRules = Struct.new(:tick_size, :step_size, :min_notional, :quote_precision)

class ScavengerTrader
  FINAL_STATUSES = %w[FILLED CANCELED REJECTED EXPIRED EXPIRED_IN_MATCH].freeze

  def initialize
    @client = BinanceClient.new
    @logged_statuses = {}
    @logged_no_funds = false
  end

  def trade
    loop { run_cycle }
  end

  private

  def run_cycle
    rules = symbol_rules
    budget = free_balance(QUOTE_ASSET).floor(rules.quote_precision)
    price = round_down(current_average_price * BUY_DISCOUNT_RATE, rules.tick_size)
    quantity = round_down(budget / price, rules.step_size)

    return wait_for_funds(budget) if quantity * price < rules.min_notional

    @logged_no_funds = false
    average_buy_price = average_price(await_fill(place_order(side: 'BUY', quantity:, price:)))

    sell(average_buy_price, rules) if average_buy_price
  end

  def sell(average_buy_price, rules)
    take_profit_price = round_down(average_buy_price * TAKE_PROFIT_RATE, rules.tick_size)
    return if sold?(place_limit_sell(take_profit_price, rules), timeout: TAKE_PROFIT_TIMEOUT)

    # The take profit price never came, so whatever is left of the position is
    # repriced closer to the buy price to free the funds for the next cycle.
    fallback_price = round_down(average_buy_price * FALLBACK_PROFIT_RATE, rules.tick_size)
    return if sold?(place_limit_sell(fallback_price, rules), timeout: FALLBACK_PROFIT_TIMEOUT)

    # Two hours without reaching even the fallback price means the market moved
    # against the position, so it is closed at any price instead of stalling the cycle.
    order = place_market_sell(rules)
    await_fill(order) if order
  end

  # A missing order means the remaining position is too small to sell, so there
  # is nothing left to wait for.
  def sold?(order, timeout:) = order.nil? || await_fill(order, timeout:)['status'] == 'FILLED'

  def place_limit_sell(price, rules)
    quantity = sellable_quantity(price, rules)

    place_order(side: 'SELL', quantity:, price:) if quantity
  end

  # Market orders carry no price, so Binance's average price estimates whether
  # the position clears the minimum order value.
  def place_market_sell(rules)
    quantity = sellable_quantity(current_average_price, rules)

    place_order(side: 'SELL', quantity:) if quantity
  end

  def sellable_quantity(price, rules)
    quantity = round_down(free_balance(BASE_ASSET), rules.step_size)

    return quantity if quantity * price >= rules.min_notional

    LOGGER.warn("Holding #{format_decimal(quantity)} #{BASE_ASSET}, which is below the minimum order value. Skipping the sell order.")
    nil
  end

  # Omitting the price places a market order.
  def place_order(side:, quantity:, price: nil)
    @client.post(
      '/api/v3/order',
      symbol: SYMBOL,
      side:,
      type: price ? 'LIMIT' : 'MARKET',
      timeInForce: price && 'GTC',
      quantity: format_decimal(quantity),
      price: price && format_decimal(price)
    )
  end

  # Polls until the order reaches a final status, cancelling it when a timeout
  # is given and reached.
  def await_fill(order, timeout: nil)
    log_status(order)
    deadline = timeout && Time.now + timeout

    loop do
      return order if FINAL_STATUSES.include?(order['status'])

      if deadline && Time.now >= deadline
        LOGGER.info("Order #{order['orderId']} is still open after #{timeout}s. Cancelling it.")
        return cancel(order)
      end

      sleep ORDER_POLL_INTERVAL
      order = fetch_order(order)
      log_status(order)
    end
  end

  def cancel(order)
    canceled = @client.delete('/api/v3/order', symbol: SYMBOL, orderId: order['orderId'])
    log_status(canceled)

    canceled
  rescue BinanceError => error
    # Binance refuses to cancel an order that filled while the request was in
    # flight, so the current state decides what happens next.
    LOGGER.warn("Order #{order['orderId']} could not be cancelled: #{error.message}")
    current = fetch_order(order)
    log_status(current)

    current
  end

  def fetch_order(order) = @client.signed_get('/api/v3/order', symbol: SYMBOL, orderId: order['orderId'])

  def symbol_rules
    symbol = @client.get('/api/v3/exchangeInfo', symbol: SYMBOL)['symbols'].first
    filters = symbol['filters'].to_h { |filter| [filter['filterType'], filter] }

    SymbolRules.new(
      BigDecimal(filters.dig('PRICE_FILTER', 'tickSize')),
      BigDecimal(filters.dig('LOT_SIZE', 'stepSize')),
      BigDecimal(filters.dig('NOTIONAL', 'minNotional')),
      symbol['quoteAssetPrecision']
    )
  end

  # Binance's rolling average smooths out momentary spikes in the order book,
  # so a single outlier trade does not set the buy price.
  def current_average_price = BigDecimal(@client.get('/api/v3/avgPrice', symbol: SYMBOL)['price'])

  def free_balance(asset)
    balance = @client.signed_get('/api/v3/account')['balances'].find { |item| item['asset'] == asset }

    balance ? BigDecimal(balance['free']) : BigDecimal(0)
  end

  def wait_for_funds(budget)
    unless @logged_no_funds
      LOGGER.info("Only #{format_decimal(budget)} #{QUOTE_ASSET} available. Skipping cycles until the account is funded.")
      @logged_no_funds = true
    end

    sleep NO_FUNDS_INTERVAL
  end

  def log_status(order)
    id = order['orderId']

    return if @logged_statuses[id] == order['status']

    @logged_statuses[id] = order['status']
    LOGGER.info(
      "Order #{id} is #{order['status']}: type=#{order['type']} side=#{order['side']} " \
      "symbol=#{order['symbol']} price=#{executed_price(order)} quantity=#{order['origQty']}"
    )
  end

  def average_price(order)
    executed_quantity = BigDecimal(order['executedQty'])

    if executed_quantity.zero?
      LOGGER.warn("Order #{order['orderId']} ended as #{order['status']} without any execution.")
      return nil
    end

    BigDecimal(order['cummulativeQuoteQty']) / executed_quantity
  end

  # Once an order executes, the average price paid is logged instead of the
  # limit price, since partial fills can land at better prices.
  def executed_price(order)
    executed_quantity = BigDecimal(order['executedQty'].to_s)

    return order['price'] if executed_quantity.zero?

    format_decimal(BigDecimal(order['cummulativeQuoteQty']) / executed_quantity)
  end

  # Binance rejects any value finer than the asset precision, and rounding up
  # could spend more than the account holds.
  def round_down(value, increment) = (value / increment).floor * increment

  def format_decimal(value) = value.to_s('F')
end

# ============================================================================
# Entry point
# ============================================================================
LOGGER.info("Scavenger Trader started (implemented by #{LLM_MODEL}).")

begin
  raise 'Missing the BINANCE_API_KEY or BINANCE_API_SECRET environment variables.' if API_KEY.to_s.empty? || API_SECRET.to_s.empty?

  ScavengerTrader.new.trade
rescue SignalException => signal
  # stop.sh terminates the script, which still deserves an ending log entry.
  LOGGER.info("Scavenger Trader interrupted by #{signal.message}.")
rescue StandardError => error
  LOGGER.fatal("#{error.class}: #{error.message}")
  LOGGER.fatal(error.backtrace.join("\n")) if error.backtrace
  LOGGER.info('Scavenger Trader ended.')
  exit 1
end

LOGGER.info('Scavenger Trader ended.')
