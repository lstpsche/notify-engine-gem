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
      Notify.reset_registry! if Notify.respond_to?(:reset_registry!)
      Notify.reset_test_mode! if Notify.respond_to?(:reset_test_mode!)
    end
  end
end
