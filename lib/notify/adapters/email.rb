# frozen_string_literal: true

require "action_view"
require "net/smtp"

module Notify
  module Adapters
    class Email < Base
      # Net::SMTP#start may raise while closing a session after DATA was already accepted.
      # Keep that acceptance instead of interpreting a QUIT failure as a retryable rejection.
      module SMTPAcceptance
        private

        def start_smtp_session
          accepted = false
          connected = false
          response = nil
          super do |smtp|
            connected = true
            response = yield smtp
            accepted = true
            response
          end
        rescue StandardError => error
          return response if accepted

          failure = Email.delivery_failure(error)
          if connected && failure.code == "connection_failed"
            failure = DeliveryFailure.new("smtp_outcome_unknown", disposition: :uncertain)
          end
          raise failure, cause: nil
        end
      end

      def deliver(message_name:, to:, subject:, locals:, template_path:, options: {})
        message = build_message(message_name, to, subject, locals, template_path, options)
        delivery_method = options[:delivery_method] || email_config[:delivery_method] || :deliver_later

        case delivery_method.to_sym
        when :deliver_now
          message.deliver_now
        else
          message.deliver_later
        end
      end

      def deliver_strict(message_name:, to:, subject:, locals:, template_path:, options: {})
        prepare_strict(message_name: message_name, to: to, subject: subject, locals: locals,
          template_path: template_path, options: options).call
      end

      def prepare_strict(message_name:, to:, subject:, locals:, template_path:, options: {})
        options = options.merge(strict: true)
        message = build_message(message_name, to, subject, locals, template_path, options)
        if options[:delivery_method].to_sym == :deliver_later
          return lambda do
            enqueue_prepared(message)
          end
        end

        mail = message.message
        validate_transport!(mail)
        mail.delivery_method.extend(SMTPAcceptance) if mail.delivery_method.is_a?(Mail::SMTP)
        -> { send_prepared(message, mail) }
      rescue DeliveryFailure => error
        raise error, cause: nil
      rescue StandardError
        raise DeliveryFailure.new("render_failed"), cause: nil
      end

      def send_prepared(message, mail)
        message.deliver_now
        raise DeliveryFailure, "delivery_suppressed" unless mail.perform_deliveries
        unless mail.raise_delivery_errors
          raise DeliveryFailure.new("delivery_errors_disabled", disposition: :uncertain)
        end

        status = mail.delivery_method.is_a?(Mail::TestMailer) || mail.delivery_method.is_a?(Mail::FileDelivery) ? :captured : :accepted
        DeliveryResult.new(adapter: :email, status: status, provider_id: mail.message_id)
      rescue DeliveryFailure => error
        raise error, cause: nil
      rescue StandardError => error
        raise self.class.delivery_failure(error), cause: nil
      end

      def enqueue_prepared(message)
        message.deliver_later
        DeliveryResult.new(adapter: :email, status: :enqueued)
      rescue StandardError
        raise DeliveryFailure.new("enqueue_outcome_unknown", disposition: :uncertain), cause: nil
      end

      def self.template_extensions
        formats = begin
          ActionView::Template::Types.symbols
        rescue StandardError
          %i[html text]
        end
        handlers = ActionView::Template::Handlers.extensions

        extensions = []
        formats.each do |format|
          handlers.each do |handler|
            extensions << :"#{format}.#{handler}"
          end
        end
        handlers.each { |h| extensions << h }

        extensions.uniq
      end

      def self.delivery_failure(error)
        if error.is_a?(Net::SMTPServerBusy)
          DeliveryFailure.new("smtp_temporary_rejection", disposition: :retryable)
        elsif error.is_a?(Net::SMTPFatalError) || error.is_a?(Net::SMTPAuthenticationError) || error.is_a?(Net::SMTPSyntaxError)
          DeliveryFailure.new("smtp_rejected")
        elsif [SocketError, Net::OpenTimeout, Errno::ECONNREFUSED, Errno::EHOSTUNREACH].any? { |klass| error.is_a?(klass) }
          DeliveryFailure.new("connection_failed", disposition: :retryable)
        else
          DeliveryFailure.new("smtp_outcome_unknown", disposition: :uncertain)
        end
      end

      private

      def build_message(message_name, to, subject, locals, template_path, options)
        subject = apply_subject_prefix(subject)
        from = options[:from]
        cc = options[:cc]
        bcc = options[:bcc]
        mailer = options[:strict] ? Notify::StrictMailer : Notify::Mailer
        configure_mailer!(mailer)

        extra = {}
        extra[:message_id] = options[:message_id] if options[:message_id]
        extra[:delivery_options] = options[:delivery_options] if options[:delivery_options]&.any?
        attributes = {
          locals: locals,
          to: Array(to),
          subject: subject,
          from: from,
          cc: cc,
          bcc: bcc,
          template_path: template_path.to_s,
          **extra
        }
        if options[:strict]
          mailer.with(attributes).dispatch_strict(message_name)
        else
          mailer.dispatch(message_name, **attributes)
        end
      end

      def validate_transport!(mail)
        raise DeliveryFailure, "delivery_suppressed" unless mail.perform_deliveries
        raise DeliveryFailure, "delivery_errors_disabled" unless mail.raise_delivery_errors
        unless [Mail::SMTP, Mail::Sendmail, Mail::TestMailer, Mail::FileDelivery].any? { |klass| mail.delivery_method.is_a?(klass) }
          raise DeliveryFailure, "unsupported_email_transport"
        end
      end

      def email_config
        Notify.config.adapters[:email] || {}
      end

      def apply_subject_prefix(subject)
        prefix = email_config[:subject_prefix]
        return subject if prefix.nil?

        prefix_str = prefix.respond_to?(:call) ? prefix.call : prefix.to_s
        return subject if prefix_str.nil? || prefix_str.to_s.strip.empty?

        "#{prefix_str} #{subject}"
      end

      def configure_mailer!(mailer = Notify::Mailer)
        configure_layout!(mailer)
        configure_helpers!(mailer)
      end

      def configure_layout!(mailer = Notify::Mailer)
        mailer.layout(email_config[:layout] || false)
      end

      def configure_helpers!(mailer = Notify::Mailer)
        helpers = email_config[:helpers]
        return unless helpers.is_a?(Array) && helpers.any?

        helpers.each { |helper_module| mailer.helper(helper_module) }
      end
    end
  end
end
