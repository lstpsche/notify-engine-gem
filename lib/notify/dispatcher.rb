# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "active_support/notifications"

module Notify
  class Dispatcher
    ADAPTER_RESOLUTION = {
      email: {
        recipient_method: :email_recipients,
        recipient_kwarg: :email_to,
        config_recipients_key: :email_recipients,
        default_recipients_key: :default_recipients,
        requires_subject: true
      },
      telegram: {
        recipient_method: :tg_recipients,
        recipient_kwarg: :tg_bots,
        config_recipients_key: :tg_recipients,
        default_recipients_key: nil,
        requires_subject: false
      }
    }.freeze

    def dispatch(name, **payload)
      name = name.to_sym
      validate_message!(name)

      payload_instance = resolve_payload_class(name, payload)
      adapter_keys = resolve_enabled_adapters(name)
      errors = {}

      ActiveSupport::Notifications.instrument("notify.message.dispatch",
        message_name: name, adapters: adapter_keys) do
        adapter_keys.each do |adapter_key|
          dispatch_to_adapter(adapter_key, name, payload, payload_instance, errors)
        end
      end

      raise DeliveryError.new(errors) if errors.any? && errors.size == adapter_keys.size
    end

    def capture_for_test(name, **payload)
      name = name.to_sym
      validate_message!(name)

      payload_instance = resolve_payload_class(name, payload)
      adapter_keys = resolve_enabled_adapters(name)

      resolved_recipients = {}
      resolved_subject = nil
      resolved_locals = nil
      errors = {}

      adapter_keys.each do |adapter_key|
        resolution = adapter_resolution_config(adapter_key)
        begin
          recipients = resolve_recipients(adapter_key, resolution, payload_instance, payload, name)
          subj = resolve_subject(adapter_key, resolution, payload_instance, payload, name)
          locals = resolve_locals(payload_instance, payload)

          resolved_recipients[adapter_key] = recipients
          resolved_subject = subj if subj && resolved_subject.nil?
          resolved_locals ||= locals
        rescue => e
          errors[adapter_key] = e
        end
      end

      delivery = {
        name: name,
        adapters: adapter_keys,
        payload: payload,
        resolved: {
          subject: resolved_subject,
          recipients: resolved_recipients,
          locals: resolved_locals || resolve_locals(payload_instance, payload)
        }
      }
      delivery[:errors] = errors if errors.any?
      delivery
    end

    private

    def validate_message!(name)
      unless Notify.registry&.message?(name)
        raise UnknownMessage, "Unknown message: #{name.inspect}"
      end
    end

    def resolve_payload_class(name, payload)
      class_name = "NotifyTemplates::#{name.to_s.camelize}"
      klass = class_name.safe_constantize
      return nil unless klass.is_a?(Class) && klass < PayloadClass

      klass.new(**payload)
    rescue => e
      log_warn("[Notify] PayloadClass #{class_name} failed to initialize: #{e.message}")
      nil
    end

    def resolve_enabled_adapters(name)
      registry_adapters = Notify.registry.adapters_for(name)
      registered_classes = Notify.registered_adapters

      registry_adapters.select do |adapter_key|
        adapter_class = registered_classes[adapter_key]
        unless adapter_class
          log_warn("[Notify] Adapter :#{adapter_key} has templates but no registered class — skipping")
          next false
        end

        adapter_cfg = adapter_config(adapter_key)
        adapter_cfg.fetch(:enabled, true)
      end
    end

    def dispatch_to_adapter(adapter_key, name, raw_payload, payload_instance, errors)
      adapter_class = Notify.registered_adapters[adapter_key]
      resolution = adapter_resolution_config(adapter_key)

      recipients = resolve_recipients(adapter_key, resolution, payload_instance, raw_payload, name)
      subject = resolve_subject(adapter_key, resolution, payload_instance, raw_payload, name)
      locals = resolve_locals(payload_instance, raw_payload)
      options = resolve_options(adapter_key, payload_instance, raw_payload, name)
      template_path = Notify.registry.templates_path.join(adapter_key.to_s)

      ActiveSupport::Notifications.instrument("notify.adapter.deliver",
        message_name: name, adapter: adapter_key, to: recipients) do
        adapter_class.new.deliver(
          message_name: name,
          to: recipients,
          subject: subject,
          locals: locals,
          template_path: template_path,
          options: options
        )
      end
    rescue => e
      errors[adapter_key] = e
      ActiveSupport::Notifications.instrument("notify.adapter.error",
        message_name: name, adapter: adapter_key, error: e)
      log_error("[Notify] Adapter :#{adapter_key} failed for :#{name}: #{e.message}")
    end

    def adapter_resolution_config(adapter_key)
      ADAPTER_RESOLUTION[adapter_key] || {
        recipient_method: :"#{adapter_key}_recipients",
        recipient_kwarg: :to,
        config_recipients_key: :recipients,
        default_recipients_key: :default_recipients,
        requires_subject: false
      }
    end

    def resolve_recipients(adapter_key, resolution, payload_instance, raw_payload, name)
      recipients =
        payload_instance&.resolve(resolution[:recipient_method]) ||
        raw_payload[resolution[:recipient_kwarg]] ||
        resolve_callable(message_config(name)&.dig(resolution[:config_recipients_key])) ||
        (resolution[:default_recipients_key] && resolve_callable(adapter_config(adapter_key)&.dig(resolution[:default_recipients_key])))

      recipients = Array(recipients)

      if recipients.empty?
        raise MissingRecipients, "No recipients resolvable for adapter :#{adapter_key}"
      end

      recipients
    end

    def resolve_subject(adapter_key, resolution, payload_instance, raw_payload, name)
      subject =
        payload_instance&.resolve(:subject) ||
        raw_payload[:subject] ||
        resolve_callable(message_config(name)&.dig(:subject))

      if resolution[:requires_subject] && (subject.nil? || subject.to_s.strip.empty?)
        raise MissingSubject, "No subject resolvable for adapter :#{adapter_key}"
      end

      subject
    end

    def resolve_locals(payload_instance, raw_payload)
      if payload_instance
        payload_instance.resolve_locals
      else
        raw_payload.reject { |k, _| PayloadClass::RESERVED_KEYS.include?(k) }
      end
    end

    def resolve_options(adapter_key, payload_instance, raw_payload, name)
      options = {}

      if adapter_key == :email
        options[:from] =
          payload_instance&.resolve(:email_from) ||
          raw_payload[:email_from] ||
          resolve_callable(message_config(name)&.dig(:email_from)) ||
          resolve_callable(adapter_config(adapter_key)&.dig(:from))

        cc = payload_instance&.resolve(:email_cc) ||
             raw_payload[:email_cc] ||
             resolve_callable(message_config(name)&.dig(:email_cc))
        options[:cc] = cc if cc

        bcc = payload_instance&.resolve(:email_bcc) ||
              raw_payload[:email_bcc] ||
              resolve_callable(message_config(name)&.dig(:email_bcc))
        options[:bcc] = bcc if bcc
      end

      options[:delivery_method] =
        raw_payload[:delivery_method] ||
        resolve_callable(message_config(name)&.dig(:delivery_method)) ||
        resolve_callable(adapter_config(adapter_key)&.dig(:delivery_method))

      options
    end

    def resolve_callable(value)
      value.respond_to?(:call) ? value.call : value
    end

    def message_config(name)
      Notify.config.messages[name]
    end

    def adapter_config(adapter_key)
      Notify.config.adapters[adapter_key] || {}
    end

    def log_warn(message)
      Rails.logger.warn(message) if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
    end

    def log_error(message)
      Rails.logger.error(message) if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
    end
  end
end
