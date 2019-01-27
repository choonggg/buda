# frozen_string_literal: true

RSpec.describe Buda do
  include Rack::Test::Methods

  let(:app) { Buda.new }

  it "returns" do
    get '/'
    expect(last_response.status).to eq(200)
  end

  it "has a version number" do
    expect(Buda::VERSION).not_to be nil
  end
end
