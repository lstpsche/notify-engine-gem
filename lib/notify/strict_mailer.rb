# frozen_string_literal: true

module Notify
  class StrictMailDeliveryJob < ActionMailer::MailDeliveryJob
    self.log_arguments = false
  end

  # Reuses the ordinary mailer while keeping strict destinations/content out of mail telemetry.
  class StrictMailer < Mailer
    self.delivery_job = StrictMailDeliveryJob

    # Parameterized delivery keeps process.action_mailer args limited to the message name.
    def dispatch_strict(message_name)
      attributes = params.to_h.symbolize_keys
      @_strict_recipient = attributes.fetch(:to).fetch(0).dup.freeze
      message = dispatch(message_name, **attributes.merge(strict: true))
      message.delivery_handler = self
      message
    rescue DeliveryFailure => error
      raise error, cause: nil
    rescue StandardError
      raise DeliveryFailure.new("render_failed"), cause: nil
    end

    # Mail invokes its handler after interceptors and before the transport.
    def deliver_mail(mail, &block)
      Adapters::Email.validate_transport!(mail)
      unless mail.destinations == [@_strict_recipient] && Array(mail.smtp_envelope_to) == [@_strict_recipient]
        raise DeliveryFailure.new("recipient_changed", attempted: false), cause: nil
      end

      mail.delivery_method.extend(Adapters::Email::SMTPAcceptance) if mail.delivery_method.is_a?(Mail::SMTP)
      self.class.deliver_mail(mail, &block)
    end

    class << self
      def deliver_mail(mail)
        super do
          yield
        rescue DeliveryFailure => error
          raise error, cause: nil
        rescue StandardError => error
          # Sanitize before ActiveSupport adds the exception to its event and logs it.
          raise Adapters::Email.delivery_failure(error), cause: nil
        end
      end

      private

      def set_payload_for_mail(payload, mail)
        super
        %i[mail subject to from cc bcc].each { |key| payload[key] = "[FILTERED]" if payload.key?(key) }
      end
    end
  end
end
