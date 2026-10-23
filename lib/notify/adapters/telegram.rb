# frozen_string_literal: true

module Notify
  module Adapters
    class Telegram < Base
      def deliver(message_name:, to:, subject:, locals:, template_path:, options: {})
        Array(to).each do |name|
          bot = bot_config(name)
          next unless bot.fetch(:enabled, true)

          deliver_strict(message_name: message_name, to: { bot: name, chat_id: bot[:chat_id] },
            subject: subject, locals: locals, template_path: template_path, options: options)
        end
      end

      def deliver_strict(message_name:, to:, subject:, locals:, template_path:, options: {})
        prepare_strict(message_name: message_name, to: to, subject: subject, locals: locals,
          template_path: template_path, options: options).call
      end

      def prepare_strict(message_name:, to:, subject:, locals:, template_path:, options: {})
        bot = bot_config(to.fetch(:bot))
        raise DeliveryFailure, "bot_disabled" unless bot.fetch(:enabled, true)

        text = TelegramRenderer.new.render(message_name: message_name, locals: locals, template_path: template_path)
        token = bot[:token]
        token = token.call if token.respond_to?(:call)
        TelegramClient.validate!(token: token, chat_id: to.fetch(:chat_id), text: text)
        chat_id = to.fetch(:chat_id).dup
        timeouts = TelegramClient.timeouts
        -> { TelegramClient.new.send_message(token: token, chat_id: chat_id, text: text, timeouts: timeouts) }
      rescue DeliveryFailure => error
        raise error, cause: nil
      rescue StandardError
        raise DeliveryFailure.new("invalid_bot_configuration"), cause: nil
      end

      def self.template_extensions
        ActionView::Template::Handlers.extensions.map { |handler| :"text.#{handler}" }
      end

      private

      def bot_config(name)
        bots = Notify.config.adapters.fetch(:telegram).fetch(:bots)
        bot = bots.find { |item| item.fetch(:name).to_s == name.to_s }
        raise DeliveryFailure, "unknown_bot" unless bot

        bot
      end
    end
  end
end
