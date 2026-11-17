# frozen_string_literal: true

# The file an app's Bundler.require loads for `gem "noticed-openwa"`.
RSpec.describe "noticed-openwa" do # rubocop:disable RSpec/DescribeClass
  subject(:load_gem) { require "noticed-openwa" }

  it "loads the gem under its name" do
    expect { load_gem }.not_to raise_error
  end
end
