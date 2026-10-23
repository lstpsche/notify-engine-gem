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
      dispatch(message_name, **params.to_h.symbolize_keys.merge(strict: true))
    rescue DeliveryFailure => error
      raise error, cause: nil
    rescue StandardError
      raise DeliveryFailure.new("render_failed"), cause: nil
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
