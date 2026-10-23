# frozen_string_literal: true

module Notify
  module TestHelper
    def assert_notify_dispatched(name, count: nil, to: nil)
      name = name.to_sym
      matching = Notify.deliveries.select { |d| d[:name] == name }

      if matching.empty?
        delivered = Notify.deliveries.map { |d| d[:name] }.inspect
        raise "Expected Notify.message(:#{name}) to have been dispatched, but it was not. " \
              "Deliveries: #{delivered}"
      end

      if count && matching.size != count
        raise "Expected #{count} dispatch(es) of :#{name}, got #{matching.size}"
      end

      if to
        expected = to.is_a?(Hash) ? [to] : Array(to)
        all_recipients = matching.flat_map do |d|
          (d[:resolved][:recipients] || {}).values.flatten
        end

        missing = expected - all_recipients
        unless missing.empty?
          raise "Expected recipients #{expected.inspect} for :#{name}, " \
                "but #{missing.inspect} not found in resolved recipients: #{all_recipients.inspect}"
        end
      end

      true
    end

    def last_notify_delivery
      Notify.deliveries.last
    end

    def setup_notify_test_mode
      Notify.test_mode!
      Notify.deliveries.clear
    end
  end
end
