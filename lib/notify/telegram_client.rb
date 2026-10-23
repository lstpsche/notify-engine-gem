# frozen_string_literal: true

require "net/http"
require "json"

module Notify
  class TelegramClient
    MAX_RESPONSE_BYTES = 65_536
    REASONS = {
      "Forbidden: bot is not a member of the channel chat" => "bot_not_member",
      "Forbidden: bot was kicked from the channel chat" => "bot_not_member",
      "Forbidden: bot was kicked from the supergroup chat" => "bot_not_member",
      "Forbidden: bot was blocked by the user" => "bot_blocked",
      "Bad Request: chat not found" => "chat_unavailable",
      "Bad Request: not enough rights to send text messages to the chat" => "posting_forbidden",
      "Bad Request: not enough rights to send text messages to the channel" => "posting_forbidden",
      "Bad Request: CHAT_WRITE_FORBIDDEN" => "posting_forbidden"
    }.freeze

    def self.valid_chat_id?(value)
      value.is_a?(String) && value.length <= 64 && value.match?(/\A(?:-?[1-9]\d*|@[a-zA-Z][a-zA-Z0-9_]{4,31})\z/)
    end

    def self.validate!(token:, chat_id:, text:)
      unless token.is_a?(String) && token.length <= 256 && token.match?(/\A\d+:[A-Za-z0-9_-]+\z/)
        raise DeliveryFailure, "invalid_bot_token"
      end
      raise DeliveryFailure, "invalid_recipient" unless valid_chat_id?(chat_id)
      unless text.is_a?(String) && text.valid_encoding? && text.length.between?(1, 4096)
        raise DeliveryFailure, "invalid_message_length"
      end
    end

    def self.timeouts
      config = Notify.config.adapters.fetch(:telegram)
      { open_timeout: config.fetch(:open_timeout, 5), read_timeout: config.fetch(:read_timeout, 15),
        write_timeout: config.fetch(:write_timeout, 15) }.tap do |options|
        unless options.values.all? { |value| (value.is_a?(Integer) || value.is_a?(Float)) && value.finite? && value.positive? }
          raise DeliveryFailure, "invalid_delivery_options"
        end
      end
    end

    def send_message(token:, chat_id:, text:, timeouts: self.class.timeouts)
      transmitting = false
      self.class.validate!(token: token, chat_id: chat_id, text: text)
      http = Net::HTTP.new("api.telegram.org", 443)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = timeouts.fetch(:open_timeout)
      http.read_timeout = timeouts.fetch(:read_timeout)
      http.write_timeout = timeouts.fetch(:write_timeout)
      http.max_retries = 0
      request = Net::HTTP::Post.new("/bot#{token}/sendMessage", "Content-Type" => "application/json")
      request.body = JSON.generate(chat_id: chat_id, text: text, link_preview_options: { is_disabled: true })
      status = nil
      body = +""
      http.start do |connection|
        transmitting = true
        connection.request(request) do |response|
          status = response.code.to_i
          response.read_body do |chunk|
            raise DeliveryFailure.new("telegram_outcome_unknown", disposition: :uncertain) if body.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES
            body << chunk
          end
        end
      end
      result(status, body)
    rescue DeliveryFailure => error
      raise error, cause: nil
    rescue StandardError
      code = transmitting ? "telegram_outcome_unknown" : "connection_failed"
      raise DeliveryFailure.new(code, disposition: transmitting ? :uncertain : :retryable), cause: nil
    end

    private

    def result(status, body)
      data = JSON.parse(body)
      unless data.is_a?(Hash)
        raise DeliveryFailure.new("telegram_outcome_unknown", disposition: :uncertain, http_status: status)
      end
      if status.between?(200, 299) && data["ok"] == true && data["result"].is_a?(Hash) &&
          data["result"]["message_id"].is_a?(Integer) && data["result"]["message_id"].positive?
        return DeliveryResult.new(adapter: :telegram, status: :accepted, provider_id: data["result"]["message_id"])
      end
      if data["ok"] == false && data["error_code"].is_a?(Integer) && data["error_code"].between?(400, 599)
        provider_code = data["error_code"]
        parameters = data["parameters"].is_a?(Hash) ? data["parameters"] : {}
        retry_after = parameters["retry_after"]
        retry_after = nil unless retry_after.is_a?(Integer) && retry_after.positive?
        code = if parameters["migrate_to_chat_id"].is_a?(Integer)
          "chat_migrated"
        elsif provider_code == 401
          "invalid_bot_token"
        elsif provider_code == 429
          "rate_limited"
        else
          REASONS.fetch(data["description"], "telegram_rejected")
        end
        disposition = provider_code == 429 || provider_code >= 500 ? :retryable : :permanent
        raise DeliveryFailure.new(code, disposition: disposition, http_status: status,
          provider_error_code: provider_code, retry_after: retry_after)
      end
      raise DeliveryFailure.new("telegram_outcome_unknown", disposition: :uncertain, http_status: status)
    rescue JSON::ParserError
      raise DeliveryFailure.new("telegram_outcome_unknown", disposition: :uncertain, http_status: status), cause: nil
    end
  end
end
