# frozen_string_literal: true

module Notify
  DeliveryResult = Struct.new(:adapter, :status, :provider_id, keyword_init: true) do
    def initialize(adapter:, status:, provider_id: nil)
      raise ArgumentError, "Invalid delivery status" unless %i[accepted enqueued captured].include?(status.to_sym)

      super(adapter: adapter.to_sym, status: status.to_sym, provider_id: provider_id&.to_s)
      freeze
    end
  end
end
