# frozen-string-literal: true

require "rack"
require "thread"
require_relative "buda/version"

class Buda
  class Error < StandardError; end

  # Threadsafe cache class, offering only #[] and #[]= methods,
  # each protexted by a mutex.
  class BudaCache
    def initialize
      @mutex = Mutex.new
      @hash = {}
    end

    # Getter for underlying hash thread safe.
    def [](key)
      @mutex.synchronize{ @hash[key] }
    end

    # Setter for underlying hash thread safe.
    def []=(key, value)
      @mutex.synchronize{ hash[key] = value }
    end

    private

    # Create a copy of the cache with a separate mutex
    def initialize_copy(other)
      @mutex = Mutex.new
      other.instance_variable_get(:@mutex).synchronize do
        @hash = other.instance_variable_get(:@hash).dup
      end
    end
  end

  # Base class for Buda request.
  class BudaRequest < ::Rack::Request
    @buda_class = ::Buda
    @match_pattern_cache = ::Buda::BudaCache.new

    # Current captures for the request.
    # This gets modified as routing occurs
    attr_reader :captures

    # The roda instance related to this request object.
    # Useful if routing methods needs access to the
    # scope of Buda route block
    attr_reader :scope

    def initialize(scope, env)
      @scope = scope
      @captures = []
      @remaining_path = _remaining_path(env)
      @env = env
    end
  end

  # Base class for Buda responses.
  class BudaResponse
    @buda_class = ::Buda
  end

  @app = nil
  @inherit_middleware = true
  @middleware = []
  @opts = {}
  @route_block = nil

  # Modules which all Buda plugins should be stored, Also
  # contains logic for registering and loading plugins.
  module BudaPlugins
    OPTS = {}.freeze
    EMPTY_ARRAY = [].freeze

    # Store registered plugins
    @plugins = BudaCache.new

    class << self
      # Make warn a public method, as it is used for deprecation
      # warnings. Buda::BudaPlugins.warn can be overridden for 
      # custom handling of deprecation warnings.
      public :warn
    end

    # If registered plugin already exists, use it. Otherwise,
    # require it and return it. Raise a LoadError if plugin
    # doesn't exist, or a BudaError if it exists but does not
    # register itself correctly.
    def self.load_plugin(name)
      h = @plugins
      unless plugin = h[name]
        require "buda/plugins/#{name}"
        raise BudaError, "Plugin #{name} did not register itself correctly in Buda::BudaPlugins" unless plugin = h[name]
      end
      plugin
    end

    # Register the give plugin with Buda, so that it can be loaded using #plugin
    # with a symbol. Should by used by plugin files. Example:
    #
    #   Buda::BudaPlugin.register_plugin(:plugin_name, PluginModule)
    def self.register_plugin(name, mod)
      @plugins[name] = mod
    end

    # Deprecate the constant with the given name in the given module,
    # if the ruby version supports it.
    def self.deprecate_constant(mod, name)
      if RUBY_VERSION >= "2.3"
        mod.deprecate_constant(name)
      end
    end

    # The base plugin for Buda, implementing all default functionality.
    # Methods are put into a plugin so future plugins can easily override 
    # them and call super to get the default behaviour.
    # Buda::BudaPlugins::Base
    module Base
      # Class methods for the Buda class.
      module ClassMethods
        # The rack application this class uses
        attr_reader :app

        # Whether middleware from the current class should be inherited by subclasses.
        # True by default, should set to false where parent class accepts request and
        # dispatch request to subclasses
        attr_accessor :inherit_middleware

        # The settings/options hash for the current class
        attr_reader :opts

        # The route block that this class uses
        attr_reader :route_block

        # Call the internal rack application with the given environment.
        # This allows the class itself to be used as a rack application.
        # However, for performance. It is better to use #app to get direct
        # access to the underlying rack app.
        def call(env)
          app.call(env)
        end

        # Clear the middleware stack
        def middleware_clear!
          @middleware.clear
          build_rack_app
        end

        # Expand path given root argument as base directory
        def expand_path(path, root=opts[:root])
          ::File.expand_path(path, root)
        end

        # Freeze internal state of class, to avoid thread safety issues at runtime.
        # It is optional to call #freeze as nothing should be modifying the internal
        # state runtime anyway, but this makes sure exception will be raised if you try
        # to modify the internal state after calling this.
        #
        # Note: Freezing the class prevents you from subclassing it, mostly because
        # it will cause some plugins to break.
        def freeze
          @opts.freeze
          @middleware.freeze
          super
        end

        # When inheriting Buda, copy the shared data into the subclass,
        # and setup the request and response subclasses.
        def inherited(subclass)
          raise BudaError, "Cannot subclass a frozen Buda class" if frozen?
          super
          subclass.instance_variable_set(:@inherit_middleware, @inherit_middleware)
          subclass.instance_variable_set(:@middleware, @inherit_middleware ? @middleware.dup : [])
          subclass.instance_variable_set(:@opts, opts.dup)
          subclass.opts.to_a.each do |k,v|
            if (v.is_a?(Array) || v.is_a?(Hash)) && !v.frozen?
              subclass.opts[k] = v.dup
            end
          end
          subclass.instance_variable_set(:@route_block, @route_block)
          subclass.send(:build_rack_app)
          
          # request_class = Class.new(self::BudaRequest)
          # request_class.buda_class = subclass
          # request_class.match_pattern_cache = BudaCache.new
          # subclass.const_set(:BudaRequest, request_class)
          #
          # response_class = Class.new(self::BudaResponse)
          # response_class.buda_class = subclass
          # subclass.const_set(:BudaResponse, response_class)
        end

        def plugin(plugin, *args, &block)
          raise BudaError, "Cannot add a plugin to a frozen Buda class" if frozen?
          plugin = BudaPlugins.load_plugin(plugin) if plugin.is_a?(Symbol)
          include(plugin::InstanceMethods) if defined?(plugin::InstanceMethods)
          extend(plugin::ClassMethods) if defined?(plugin::ClassMethods)
          self::BudaRequest.send(:include, plugin::RequestMethods) if defined?(plugin::RequestMethods)
          self::BudaRequest.extend(plugin::RequestClassMethods) if defined?(plugin::RequestClassMethods)
          self::BudaResponse.send(:include, plugin::ResponseMethods) if defined?(plugin::ResponseMethods)
          self::BudaResponse.extend(plugin::ResponseClassMethods) if defined?(plugin::ResponseClassMethods)
          plugin.configure(self, *args, &block) if plugin.respond_to?(:configure)
          nil
        end

        # Setup routing tree for current Buda application, and build underlying rack
        # application using stored middleware. Requires a block which is yield the 
        # request. By convention, the block argument should be named +r+. Example:
        #
        #   Buda.route do |r|
        #     r.root do
        #       "Root"
        #     end
        #   end
        #
        # Should only be called once per class.
        # Multiple calls will overwrite previous routing.
        def route(&block)
          @route_block = block
          build_rack_app
        end

        # adds middleware to the rack application. Must be called
        # before calling #route to have an effect. Example:
        #
        # Buda.use Rack::ShowExceptions
        def use(*args, &block)
          @middleware << [args, block].freeze
          build_rack_app
        end

        private

        # build_the_rack_app
        def build_rack_app
          if block = @route_block
            block = rack_app_route_block(block)
            app = lambda{ |env| new(env).call(&block) }
            @middleware.reverse_each do |args, bl|
              mid, *args = args
              app = mid.new(app, *args, bl)
              app.freeze if opts[:freeze_middleware]
            end
            @app = app
          end
        end

        # The route block to use when building rack app.
        # Can be modified by plugins
        def rack_app_route_block(block)
          block
        end
      end

      # Instance methods for the Buda class.
      #
      # In addition to the listed methods, the following methods are avail:
      #
      # request :: The instance of request class related to this request.
      #            Same object yielded by Buda.route.
      # response :: The instance of the response class related to this request.
      module InstanceMethods
        # Create a request and response the appropriate class
        def initialize()
          klass = self.class
          # @_request = klass::BudaRequest.new(self, env)
          # @_response = klass::BudaResponse.new
        end

        # instance_exec the route block in the scope of the receiver,
        # with the related request. Catch :halt so that the route block
        # can throw :halt at any point with the rack response to use.
        def call(env)
          # catch(:halt) do
          #   r = @_request
          #   r.block_result(instance_exec(r, &block))
          #   @_response.finish
          # end
          [200, { "Content-Type": "text/plain" }, "Helo"]
        end

        # Private alias for internal use
        alias _call call
        private :_call

        def env
          @_request.env
        end

        def opts
          self.class.opts
        end

        attr_reader :_request
        alias request _request
        remove_method :request

        attr_reader :_response
        alias response _response
        remove_method :_response

        def session
          @_request.session
        end
      end

      # Class methods for roda request
      module RequestClassMethods
        attr_reader :buda_class
      end

    end
  end

  extend BudaPlugins::Base::ClassMethods
  plugin BudaPlugins::Base
end
