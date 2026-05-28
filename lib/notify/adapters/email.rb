# frozen_string_literal: true

require "action_view"

module Notify
  module Adapters
    class Email < Base
      def deliver(message_name:, to:, subject:, locals:, template_path:, options: {})
        subject = apply_subject_prefix(subject)
        from = options[:from]
        cc = options[:cc]
        bcc = options[:bcc]
        delivery_method = options[:delivery_method] || email_config[:delivery_method] || :deliver_later

        configure_mailer!

        message = Notify::Mailer.dispatch(
          message_name,
          locals: locals,
          to: Array(to),
          subject: subject,
          from: from,
          cc: cc,
          bcc: bcc,
          template_path: template_path.to_s
        )

        case delivery_method.to_sym
        when :deliver_now
          message.deliver_now
        else
          message.deliver_later
        end
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

      private

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

      def configure_mailer!
        configure_layout!
        configure_helpers!
      end

      def configure_layout!
        Notify::Mailer.layout(email_config[:layout] || false)
      end

      def configure_helpers!
        helpers = email_config[:helpers]
        return unless helpers.is_a?(Array) && helpers.any?

        helpers.each { |helper_module| Notify::Mailer.helper(helper_module) }
      end
    end
  end
end
