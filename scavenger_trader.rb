# AI LLM: Gemini 1.5 Pro
require 'httparty'
require 'logger'
require 'openssl'
require 'json'
require 'time'
require 'uri'

# --- Configuration & Constants ---
SYMBOL = 'ETHBRL'.freeze
BASE_ASSET = 'ETH'.freeze
QUOTE_ASSET = 'BRL'.freeze
BUY_RETRACEMENT_RATIO = 0.00382.freeze
SELL_PROFIT_RATIO = 0.00236.freeze

PRICE_PRECISION = 2.freeze
QTY_PRECISION = 4.freeze

BASE_URL = 'https://api.binance.com'.freeze
API_KEY = ENV['BINANCE_API_KEY'].freeze
API_SECRET = ENV['BINANCE_API_SECRET'].freeze

# Network error classes to catch and retry
NETWORK_ERRORS = [
  SocketError,
  EOFError,
  Errno::ECONNRESET,
  Errno::ETIMEDOUT,
  Net::OpenTimeout,
  Net::ReadTimeout,
  HTTParty::Error
].freeze

# Initialize logger
LOGGER = Logger.new('scavenger_trader.log')
LOGGER.level = Logger::INFO
LOGGER.formatter = proc do |severity, datetime, _progname, msg|
  "#{datetime.strftime('%Y-%m-%d %H:%M:%S')} [#{severity}] #{msg}\n"
end

# Check environment variables
if API_KEY.nil? || API_KEY.empty? || API_SECRET.nil? || API_SECRET.empty?
  LOGGER.fatal("BINANCE_API_KEY or BINANCE_API_SECRET environment variables are missing.")
  exit(1)
end

# --- Binance API Client ---
class BinanceClient
  include HTTParty
  base_uri BASE_URL

  def initialize(api_key, api_secret)
    @api_key = api_key
    @api_secret = api_secret
  end

  def get_price(symbol)
    response = make_request(:get, '/api/v3/ticker/price', { symbol: symbol }, false)
    response['price'].to_f
  end

  def get_balance(asset)
    response = make_request(:get, '/api/v3/account', {}, true)
    balance = response['balances'].find { |b| b['asset'] == asset }
    balance ? balance['free'].to_f : 0.0
  end

  def place_order(symbol, side, quantity, price)
    params = {
      symbol: symbol,
      side: side,
      type: 'LIMIT',
      timeInForce: 'GTC',
      quantity: format("%.#{QTY_PRECISION}f", quantity),
      price: format("%.#{PRICE_PRECISION}f", price)
    }
    make_request(:post, '/api/v3/order', params, true)
  end

  def get_order(symbol, order_id)
    make_request(:get, '/api/v3/order', { symbol: symbol, orderId: order_id }, true)
  end

  private

  def make_request(method, endpoint, params, signed)
    sleep 1 # Enforce REST API rate limit: 1 request per second

    headers = {
      'X-MBX-APIKEY' => @api_key,
      'Content-Type' => 'application/x-www-form-urlencoded'
    }

    if signed
      params[:timestamp] = (Time.now.to_f * 1000).to_i
      query_string = URI.encode_www_form(params)
      signature = OpenSSL::HMAC.hexdigest('sha256', @api_secret, query_string)
      params[:signature] = signature
    end

    begin
      response = if method == :get
                   self.class.get(endpoint, query: params, headers: headers)
                 else
                   self.class.post(endpoint, body: URI.encode_www_form(params), headers: headers)
                 end

      parsed_response = JSON.parse(response.body)

      unless response.success?
        raise StandardError, "API Error: #{parsed_response['msg']} (Code: #{parsed_response['code']})"
      end

      parsed_response
    rescue *NETWORK_ERRORS => e
      LOGGER.warn("Network error: #{e.message}. Retrying in 60 seconds...")
      sleep 60
      retry
    end
  end
end

# --- Scalping Bot Logic ---
class ScalpingBot
  def initialize
    @client = BinanceClient.new(API_KEY, API_SECRET)
  end

  def run
    LOGGER.info("Starting ETH/BRL Scalping Bot...")

    loop do
      begin
        execute_cycle
      rescue StandardError => e
        LOGGER.fatal("Unexpected error occurred: #{e.class} - #{e.message}")
        LOGGER.fatal(e.backtrace.join("\n"))
        LOGGER.info("Stopping Scalping Bot due to error.")
        exit(1)
      end
    end
  end

  private

  def execute_cycle
    fiat_balance = @client.get_balance(QUOTE_ASSET)

    # Needs minimum notional (Binance typically requires ~R$10 for BRL pairs, using 15 to be safe)
    if fiat_balance < 15.0
      sleep 10
      return
    end

    current_price = @client.get_price(SYMBOL)

    # Calculate Buy target
    buy_price = floor_val(current_price * (1.0 - BUY_RETRACEMENT_RATIO), PRICE_PRECISION)
    buy_quantity = floor_val(fiat_balance / buy_price, QTY_PRECISION)

    # Place Buy Order
    buy_order = @client.place_order(SYMBOL, 'BUY', buy_quantity, buy_price)
    log_order_change(buy_order)

    # Wait for Buy Order to fill
    wait_for_fill(buy_order['orderId'])

    # Prepare Sell Order
    crypto_balance = @client.get_balance(BASE_ASSET)
    sell_price = floor_val(buy_price * (1.0 + SELL_PROFIT_RATIO), PRICE_PRECISION)
    sell_quantity = floor_val(crypto_balance, QTY_PRECISION)

    # Place Sell Order
    sell_order = @client.place_order(SYMBOL, 'SELL', sell_quantity, sell_price)
    log_order_change(sell_order)

    # Wait for Sell Order to fill
    wait_for_fill(sell_order['orderId'])
  end

  def wait_for_fill(order_id)
    last_status = 'NEW'

    loop do
      order_info = @client.get_order(SYMBOL, order_id)
      current_status = order_info['status']

      if current_status != last_status
        log_order_change(order_info)
        last_status = current_status
      end

      break if current_status == 'FILLED'

      # Stop script if order is canceled or rejected by Binance to prevent unexpected behavior
      if %w[CANCELED REJECTED EXPIRED].include?(current_status)
        raise StandardError, "Order #{order_id} reached terminal state: #{current_status}"
      end

      sleep 2
    end
  end

  def log_order_change(order_data)
    LOGGER.info(
      "Order Status Update - " \
      "ID: #{order_data['orderId']} | " \
      "Symbol: #{order_data['symbol']} | " \
      "Type: #{order_data['type']} | " \
      "Side: #{order_data['side']} | " \
      "Status: #{order_data['status'] || 'NEW'} | " \
      "Price: #{order_data['price']} | " \
      "OrigQty: #{order_data['origQty']} | " \
      "ExecQty: #{order_data['executedQty']}"
    )
  end

  def floor_val(value, decimals)
    multiplier = 10.0**decimals
    (value * multiplier).floor / multiplier
  end
end

# --- Execution ---
trap("SIGINT") do
  LOGGER.info("Bot manually stopped by user (SIGINT).")
  exit(0)
end

trap("SIGTERM") do
  LOGGER.info("Bot terminated by system (SIGTERM).")
  exit(0)
end

ScalpingBot.new.run
