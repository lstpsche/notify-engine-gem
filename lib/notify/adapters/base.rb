# frozen_string_literal: true

module Notify
  module Adapters
    class Base
      def deliver(message_name:, to:, subject:, locals:, template_path:, options: {})
        raise Notify::NotImplementedError, "#{self.class}#deliver must be implemented"
      end

      def self.template_extensions
        raise Notify::NotImplementedError, "#{name || self}.template_extensions must be implemented"
      end
    end
  end
end
