# frozen-string-literal: true

require "rack"
require "thread"
require_relative "buda/version"

class Buda
  class Error < StandardError; end

  class BudaCache
    # Create a new thread safe cache.
    def initialize
      @mutex = Mutex.new
      @hash = {}
    end

    # Make getting value from underlying hash thread safe.
    def [](key)
      @mutex.synchronize{@hash[key]}
    end

    # Make setting value in underlying hash thread safe.
    def []=(key, value)
      @mutex.synchronize{@hash[key] = value}
    end

    private

    # Create a copy of the cache with a separate mutex.
    def initialize_copy(other)
      @mutex = Mutex.new
      other.instance_variable_get(:@mutex).synchronize do
        @hash = other.instance_variable_get(:@hash).dup
      end
    end
  end

  class BudaResponse
    @buda_class = ::Buda
    DEFAULT_HEADERS = {"Content-Type" => "text/html".freeze}.freeze

    attr_reader :body
    attr_accessor :status

    def initialize
      @status = nil
      @headers = {}
      @body = []
      @length = 0
    end

    def [](key)
      @headers[key]
    end

    def []=(key, value)
      @headers[key] = value
    end

    def default_headers
      DEFAULT_HEADERS
    end

    def empty?
      @body.empty?
    end

    def set_default_headers
      h = @headers
      default_headers.each do |k, v|
        h[k] ||= v
      end
    end

    def write(str)
      s = str.to_s
      @length += s.bytesize
      @body << s
      nil
    end

    def default_status
      200
    end

    def finish
      b = @body
      s = (@status ||= empty? ? 404 : default_status)
      set_default_headers
      h = @headers

      if empty? && (s == 304 || s == 204 || s == 205 || (s >= 100 && s <= 199))
        h.delete("Content-Type")
      else
        h["Content-Length"] ||= @length.to_s
      end

      [s, h , b]
    end
  end

  class BudaRequest < ::Rack::Request
    @buda_class = ::Buda
    @match_pattern_cache = ::Buda::BudaCache.new

    Term = Object.new
    def Term.inspect
      "TERM"
    end
    Term.freeze

    attr_reader :remaining_path
    attr_reader :captures
    attr_reader :scope

    def initialize(scope, env)
      @scope = scope
      @captures = []
      @remaining_path = _remaining_path(env)
      @env = env
    end

    def block_result_body(result)
      case result
      when String
        result
      when nil, false
        # nothing
      else
        raise BudaError, "unsupported block result"
      end
    end

    def block_result(result)
      res = response
      if res.empty? && (body = block_result_body(result))
        res.write(body)
      end
    end

    def response
      @scope.response
    end

    def _remaining_path(env)
      env["PATH_INFO"]
    end

    def always
      block_result(yield)
      throw :halt, response.finish
    end

    def is_get?
      @env["REQUEST_METHOD"] == 'GET'
    end

    def empty_path?
      remaining_path == ""
    end

    def match(matcher)
      case matcher
      when String
        _match_string(matcher)
      when Term
        empty_path?
      end
    end

    def if_match(args)
      path = @remaining_path
      @captures.clear

      if match_all(args)
        block_result(yield(*captures))
        throw :halt, response.finish
      else
        @remaining_path = path
        false
      end
    end

    def match_all(args)
      args.all?{|arg| match(arg)}
    end

    def _match_string(str)
      rp = @remaining_path
      if rp.start_with?("/#{str}")
        last = str.length + 1
        case rp[last]
        when "/"
          @remaining_path = rp[last, rp.length]
        when nil
          @remaining_path = ""
        end
      end
    end

    def _verb(args, &block)
      if args.empty?
        always(&block)
      else
        args << Term
        if_match(args, &block)
      end
    end

    def root(&block)
      if remaining_path == "/" && is_get?
        always(&block)
      end
    end

    def on(*args, &block)
      if args.empty?
        always(&block)
      else
        if_match(args, &block)
      end
    end

    def get(*args, &block)
      _verb(args, &block) if is_get?
    end
  end

  class << self
    attr_reader :app

    @app = nil
    @middleware = []
    @opts = {}
    @route_block = nil

    def route(&block)
      @route_block = block
      build_rack_app
    end

    def rack_app_route_block(block)
      block
    end

    def build_rack_app
      if block = @route_block
        block = rack_app_route_block(block)
        app = lambda{|env| new(env).call(&block) }
        @app = app
      end
    end

    def freeze
      @opts.freeze
      @middleware.freeze
      super
    end
  end

  attr_reader :_request # :nodoc:
  alias request _request
  remove_method :_request

  attr_reader :_response # :nodoc:
  alias response _response
  remove_method :_response

  def initialize(env)
    klass = self.class
    @_request = klass::BudaRequest.new(self, env)
    @_response = klass::BudaResponse.new
  end

  def call(&block)
    catch(:halt) do
      r = @_request
      r.block_result(instance_exec(r, &block))
      @_response.finish
    end
  end
end
