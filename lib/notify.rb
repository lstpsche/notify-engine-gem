# frozen_string_literal: true

require_relative "notify/version"
require_relative "notify/errors"
require_relative "notify/config"
require_relative "notify/registry"
require_relative "notify/engine"

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

    private

    def adapter_classes
      @adapter_classes ||= {}
    end
  end
end
