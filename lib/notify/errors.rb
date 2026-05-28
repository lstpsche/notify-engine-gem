# frozen_string_literal: true

module Notify
  class Error < StandardError; end
  class UnknownMessage < Error; end
  class MissingRecipients < Error; end
  class MissingSubject < Error; end
  class DeliveryError < Error; end
  class AdapterNotRegistered < Error; end
  class NotImplementedError < Error; end
end
