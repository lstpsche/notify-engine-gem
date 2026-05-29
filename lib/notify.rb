# frozen_string_literal: true

require_relative "notify/version"
require_relative "notify/errors"
require_relative "notify/config"
require_relative "notify/payload_class"
require_relative "notify/registry"
require_relative "notify/adapters/base"
require_relative "notify/mailer"
require_relative "notify/adapters/email"
require_relative "notify/dispatcher"
require_relative "notify/engine"
require_relative "notify/test_helper"

module Notify
  class << self
    def config
      @config ||= Config.new
    end

    def configure
      yield config
    end

    def reset_config!
      @config = Config.new
    end

    def register_adapter(key, klass)
      adapter_classes[key.to_sym] = klass
    end

    def registered_adapters
      adapter_classes.dup
    end

    def reset_adapters!
      @adapter_classes = {}
    end

    def registry
      @registry
    end

    def messages
      registry&.messages || {}
    end

    def adapters
      registry&.adapters || {}
    end

    def build_registry!(templates_path)
      @registry = Registry.new(templates_path)
    end

    def reset_registry!
      @registry = nil
    end

    def test_mode!
      @test_mode = true
      @deliveries ||= []
    end

    def test_mode?
      @test_mode == true
    end

    def deliveries
      @deliveries ||= []
    end

    def reset_test_mode!
      @test_mode = false
      @deliveries&.clear
    end

    def message(name, **payload)
      if test_mode?
        deliveries << Dispatcher.new.capture_for_test(name, **payload)
      else
        Dispatcher.new.dispatch(name, **payload)
      end
    end

    private

    def adapter_classes
      @adapter_classes ||= {}
    end
  end
end
