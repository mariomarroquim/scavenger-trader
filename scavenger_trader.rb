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
LLM_MODEL = 'Claude Opus 5'

API_BASE_URL = 'https://api.binance.com'
API_KEY = ENV['BINANCE_API_KEY']
API_SECRET = ENV['BINANCE_API_SECRET']
API_RECV_WINDOW = 5_000

SYMBOL = 'ETHBRL'
BASE_ASSET = 'ETH'
QUOTE_ASSET = 'BRL'

TAKE_PROFIT_RATE = BigDecimal('1.00236')
STOP_LOSS_RATE = BigDecimal('1.00175')
TAKE_PROFIT_TIMEOUT = 60 * 60

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

# Raised for gateway hiccups and malformed payloads, which are worth retrying.
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

  def initialize
    @last_request_at = Time.at(0)
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
      throttle
      perform(method, endpoint, params, signed)
    rescue *RETRYABLE_ERRORS => error
      raise NetworkError, "#{error.class}: #{error.message}" if Time.now >= deadline

      LOGGER.warn("Network failure (#{error.class}: #{error.message}). Retrying in #{NETWORK_RETRY_INTERVAL}s.")
      sleep NETWORK_RETRY_INTERVAL
      retry
    end
  end

  def perform(method, endpoint, params, signed)
    query = signed ? signed_query(params) : URI.encode_www_form(params.compact)
    url = "#{API_BASE_URL}#{endpoint}?#{query}"
    response = HTTParty.send(method, url, headers: { 'X-MBX-APIKEY' => API_KEY })

    raise TransientError, "Binance is unavailable (HTTP #{response.code})." if response.code >= 500

    body = parse(response)
    raise BinanceError, "Binance refused the request (HTTP #{response.code}): #{body['msg'] || body}." if response.code != 200

    body
  end

  def signed_query(params)
    params = params.compact.merge(timestamp: (Time.now.to_f * 1000).to_i, recvWindow: API_RECV_WINDOW)
    query = URI.encode_www_form(params)
    signature = OpenSSL::HMAC.hexdigest('SHA256', API_SECRET, query)

    "#{query}&signature=#{signature}"
  end

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

    return wait_for_funds(budget) if budget < rules.min_notional

    @logged_no_funds = false
    average_buy_price = buy(budget)

    return if average_buy_price.nil?

    sell(average_buy_price, rules)
  end

  # Spends the whole fiat balance at market price and reports the average price
  # actually paid, which both sell prices are derived from.
  def buy(budget)
    order = @client.post('/api/v3/order', symbol: SYMBOL, side: 'BUY', type: 'MARKET', quoteOrderQty: format_decimal(budget))
    order = await_fill(order)
    executed_quantity = BigDecimal(order['executedQty'])

    if executed_quantity.zero?
      LOGGER.warn("Buy order #{order['orderId']} ended as #{order['status']} without any execution.")
      return nil
    end

    BigDecimal(order['cummulativeQuoteQty']) / executed_quantity
  end

  def sell(average_buy_price, rules)
    take_profit_price = round_down(average_buy_price * TAKE_PROFIT_RATE, rules.tick_size)
    order = place_sell(take_profit_price, rules)

    return if order.nil?

    order = await_fill(order, timeout: TAKE_PROFIT_TIMEOUT)

    return if order['status'] == 'FILLED'

    # The take profit price never came, so the position is repriced closer to
    # the buy price to free the funds for the next cycle.
    stop_loss_price = round_down(average_buy_price * STOP_LOSS_RATE, rules.tick_size)
    order = place_sell(stop_loss_price, rules)

    await_fill(order) if order
  end

  def place_sell(price, rules)
    quantity = round_down(free_balance(BASE_ASSET), rules.step_size)

    if quantity * price < rules.min_notional
      LOGGER.warn("Holding #{format_decimal(quantity)} #{BASE_ASSET}, which is below the minimum order value. Skipping the sell order.")
      return nil
    end

    @client.post(
      '/api/v3/order',
      symbol: SYMBOL,
      side: 'SELL',
      type: 'LIMIT',
      timeInForce: 'GTC',
      quantity: format_decimal(quantity),
      price: format_decimal(price)
    )
  end

  # Polls until the order reaches a final status, cancelling it when a timeout
  # is given and reached.
  def await_fill(order, timeout: nil)
    log_status(order)
    deadline = timeout ? Time.now + timeout : nil

    loop do
      return order if FINAL_STATUSES.include?(order['status'])

      if deadline && Time.now >= deadline
        LOGGER.info("Order #{order['orderId']} is still open after #{timeout}s. Cancelling it.")
        return cancel(order)
      end

      sleep ORDER_POLL_INTERVAL
      order = @client.signed_get('/api/v3/order', symbol: SYMBOL, orderId: order['orderId'])
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
    current = @client.signed_get('/api/v3/order', symbol: SYMBOL, orderId: order['orderId'])
    log_status(current)

    current
  end

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

  # Market orders carry no price, so the price actually paid is reported.
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
