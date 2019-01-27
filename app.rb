require "rack"
require "thin"
require "byebug"
require './lib/buda'

class App < Buda
  route do |r|
    r.root do
      "ROOT!"
    end

    r.on "bo" do
      "Hi"
    end

    r.on "hello" do
      @hello = "Chong"

      r.get "world" do
        "#{@hello} world"
      end
    end
  end
end

Rack::Handler::Thin.run App.freeze.app
