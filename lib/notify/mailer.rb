# frozen_string_literal: true

require "action_mailer"

module Notify
  class Mailer < ActionMailer::Base
    def dispatch(message_name, locals:, to:, subject:, from: nil, cc: nil, bcc: nil, template_path: nil)
      prepend_view_path(template_path.to_s) if template_path

      bridge_locals(locals)

      mail_options = {
        to: to,
        subject: subject,
        template_name: message_name.to_s,
        template_path: ""
      }
      mail_options[:from] = from if from
      mail_options[:cc] = cc if cc
      mail_options[:bcc] = bcc if bcc

      mail(mail_options)
    end

    private

    def bridge_locals(locals)
      return unless locals.is_a?(Hash)

      locals.each do |key, value|
        key_s = key.to_s
        if key_s.start_with?("_")
          log_ivar_skip(key_s)
          next
        end
        instance_variable_set(:"@#{key_s}", value)
      end
    end

    def log_ivar_skip(key)
      return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

      Rails.logger.warn(
        "[Notify::Mailer] Skipping local '#{key}' — underscore-prefixed keys are reserved for framework internals"
      )
    end
  end
end
