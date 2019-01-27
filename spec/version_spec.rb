require_relative 'spec_helper'

RSpec.describe "Buda version constraints" do
  it "VERSION should be string in x.y.z integer format" do
    expect(Buda::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end
end
