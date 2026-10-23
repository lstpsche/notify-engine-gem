# frozen_string_literal: true

module Notify
  class Error < StandardError; end
  class UnknownMessage < Error; end
  class MissingRecipients < Error; end
  class MissingSubject < Error; end

  class DeliveryFailure < Error
    attr_reader :code, :disposition, :http_status, :provider_error_code, :retry_after

    def initialize(code, disposition: :permanent, http_status: nil, provider_error_code: nil, retry_after: nil)
      @code = code.to_s
      @disposition = disposition.to_sym
      @http_status = http_status
      @provider_error_code = provider_error_code
      @retry_after = retry_after
      super(@code)
    end
  end

  class DeliveryError < Error
    attr_reader :adapter_errors

    def initialize(adapter_errors = {})
      @adapter_errors = adapter_errors
      if adapter_errors.any?
        adapter_msgs = adapter_errors.map { |adapter, err| "#{adapter}: #{err.message}" }
        super("All adapters failed — #{adapter_msgs.join('; ')}")
      else
        super("All adapters failed")
      end
    end
  end

  class AdapterNotRegistered < Error; end
  class NotImplementedError < Error; end
end
