# frozen_string_literal: true

RSpec.configure do |config|
  config.disable_monkey_patching!

  config.expect_with :rspec do |expectations|
    expectations.syntax = :expect
  end

  config.before do
    if defined?(Notify)
      Notify.reset_config!
      Notify.reset_adapters! if Notify.respond_to?(:reset_adapters!)
    end
  end
end
