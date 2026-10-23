# frozen_string_literal: true

require "json"
require "uri"

module Notify
  # A single, explicit transport invocation. Legacy payload/default resolution is intentionally separate.
  class StrictDelivery
    def call(name, via:, to:, subject: nil, locals: {}, delivery_method: :deliver_now, message_id: nil, delivery_options: {})
      prepare(name, via: via, to: to, subject: subject, locals: locals, delivery_method: delivery_method,
        message_id: message_id, delivery_options: delivery_options).call
    end

    # Prepare/render without provider I/O, allowing a caller to persist its pre-send checkpoint afterward.
    def prepare(name, via:, to:, subject: nil, locals: {}, delivery_method: :deliver_now, message_id: nil, delivery_options: {})
      fail_with("unknown_message") unless name.is_a?(String) || name.is_a?(Symbol)
      fail_with("adapter_unavailable") unless via.is_a?(String) || via.is_a?(Symbol)
      name = name.to_sym
      adapter = via.to_sym
      validate!(name, adapter, to, subject, locals, delivery_method, delivery_options)
      fail_with("invalid_message_id") if message_id && adapter != :email
      if message_id && !(message_id.is_a?(String) && message_id.length <= 255 && message_id.match?(/\A[^<>\s@]+@[^<>\s@]+\z/))
        fail_with("invalid_message_id")
      end
      if Notify.test_mode?
        return lambda do
          Notify.deliveries << { name: name, adapters: [adapter], strict: true,
            payload: { locals: locals }, resolved: { subject: subject, recipients: { adapter => [to] }, locals: locals } }
          DeliveryResult.new(adapter: adapter, status: :captured)
        end
      end

      config = Notify.config.adapters.fetch(adapter)
      from = config[:from]
      options = { from: from.respond_to?(:call) ? from.call : from,
        delivery_method: delivery_method, message_id: message_id, delivery_options: delivery_options }
      prepared = Notify.registered_adapters.fetch(adapter).new.prepare_strict(
        message_name: name, to: to, subject: subject, locals: locals,
        template_path: Notify.registry.templates_path.join(adapter.to_s), options: options
      )
      -> { execute(name, adapter, prepared) }
    rescue DeliveryFailure => error
      ActiveSupport::Notifications.instrument("notify.adapter.error", message_name: name, adapter: adapter, error: error)
      raise error, cause: nil
    rescue StandardError => original
      error = DeliveryFailure.new("preparation_failed")
      error.set_backtrace(original.backtrace)
      ActiveSupport::Notifications.instrument("notify.adapter.error", message_name: name, adapter: adapter, error: error)
      raise error, cause: nil
    end

    private

    def execute(name, adapter, prepared)
      result = ActiveSupport::Notifications.instrument("notify.adapter.deliver", message_name: name, adapter: adapter) do
        prepared.call
      end
      unless result.is_a?(DeliveryResult) && result.adapter == adapter
        raise DeliveryFailure.new("invalid_delivery_result", disposition: :uncertain)
      end
      result
    rescue DeliveryFailure => error
      ActiveSupport::Notifications.instrument("notify.adapter.error", message_name: name, adapter: adapter, error: error)
      raise error, cause: nil
    end

    def validate!(name, adapter, to, subject, locals, delivery_method, delivery_options)
      fail_with("unknown_message") unless Notify.registry&.adapters_for(name)&.include?(adapter)
      klass = Notify.registered_adapters[adapter]
      fail_with("adapter_unavailable") unless klass&.method_defined?(:prepare_strict)
      fail_with("adapter_disabled") unless Notify.config.adapters.fetch(adapter, {}).fetch(:enabled, true)
      fail_with("invalid_locals") unless locals.is_a?(Hash) && json_value?(locals)
      fail_with("invalid_delivery_method") unless delivery_method.respond_to?(:to_sym) &&
        %i[deliver_now deliver_later].include?(delivery_method.to_sym)
      fail_with("invalid_delivery_options") unless delivery_options.is_a?(Hash) && delivery_options.all? do |key, value|
        %i[open_timeout read_timeout].include?(key) && value.is_a?(Numeric) && value.finite? &&
          value.respond_to?(:positive?) && value.positive?
      end
      if adapter == :email
        fail_with("invalid_recipient") unless to.is_a?(String) && to.length <= 254 &&
          to.match?(URI::MailTo::EMAIL_REGEXP) && !to.match?(/[\r\n,;]/)
        fail_with("missing_subject") unless subject.is_a?(String) && !subject.strip.empty? && !subject.match?(/[\r\n]/)
      elsif adapter == :telegram
        fail_with("invalid_delivery_options") unless delivery_method.to_sym == :deliver_now
        fail_with("invalid_recipient") unless to.is_a?(Hash) && to.size == 2 && to.key?(:bot) && to.key?(:chat_id) &&
          to[:bot].respond_to?(:to_sym) && TelegramClient.valid_chat_id?(to[:chat_id])
        bot = Notify.config.adapters.fetch(:telegram).fetch(:bots).find { |item| item[:name].to_s == to[:bot].to_s }
        fail_with("unknown_bot") unless bot
        fail_with("bot_disabled") unless bot.fetch(:enabled, true)
        fail_with("invalid_delivery_options") unless delivery_options.empty?
      else
        fail_with("unsupported_strict_adapter")
      end
    end

    def json_value?(value, depth = 0)
      return false if depth > 20
      case value
      when Hash then value.all? { |key, item| (key.is_a?(String) || key.is_a?(Symbol)) && json_value?(item, depth + 1) }
      when Array then value.all? { |item| json_value?(item, depth + 1) }
      when String, Integer, true, false, nil then true
      when Float then value.finite?
      else false
      end
    end

    def fail_with(code)
      raise DeliveryFailure, code
    end
  end
end
