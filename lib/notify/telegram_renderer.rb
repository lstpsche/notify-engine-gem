# frozen_string_literal: true

require "action_view"

module Notify
  class TelegramRenderer
    def render(message_name:, locals:, template_path:)
      view = ActionView::Base.with_empty_template_cache.with_view_paths([template_path.to_s], locals.stringify_keys)
      view.render(template: message_name.to_s, formats: [:text], locals: locals.symbolize_keys)
    rescue StandardError
      raise DeliveryFailure.new("render_failed"), cause: nil
    end
  end
end
