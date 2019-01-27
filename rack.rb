require "rack"
require "thin"

class HelloWorld
  def call(env)
    ["200", {'Content-Type' => 'text/html'}, env]
  end
end

Rack::Handler::Thin.run HelloWorld.new
