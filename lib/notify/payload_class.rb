# frozen_string_literal: true

module Notify
  class PayloadClass
    RESERVED_KEYS = %i[subject email_to email_from email_cc email_bcc tg_bots delivery_method].freeze

    DSL_METHODS = %i[subject email_recipients email_from email_cc email_bcc tg_recipients locals].freeze

    class << self
      def dsl_definitions
        @_dsl_definitions ||= {}
      end

      DSL_METHODS.each do |method_name|
        define_method(method_name) do |value = nil, &block|
          if value.nil? && block.nil?
            dsl_definitions[method_name]
          else
            dsl_definitions[method_name] = block || value
          end
        end
      end
    end

    def self.new(**payload)
      instance = allocate
      instance.instance_variable_set(:@_raw_payload, payload.freeze)
      instance.send(:initialize, **payload)
      instance
    end

    def initialize(**payload); end

    def resolve(name)
      if respond_to?(name)
        public_send(name)
      elsif self.class.dsl_definitions.key?(name)
        dsl_val = self.class.dsl_definitions[name]
        dsl_val.respond_to?(:call) ? instance_exec(&dsl_val) : dsl_val
      end
    end

    def resolve_locals
      result = resolve(:locals)
      result.nil? ? default_locals : result
    end

    def default_locals
      @_raw_payload.reject { |k, _| RESERVED_KEYS.include?(k) }
    end
  end
end
