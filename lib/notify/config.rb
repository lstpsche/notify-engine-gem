# frozen_string_literal: true

module Notify
  class Config
    attr_accessor :templates_path
    attr_reader :adapters, :messages

    def initialize
      @templates_path = "app/notify_templates"
      @adapters = {
        email: {
          enabled: true,
          from: nil,
          delivery_method: :deliver_later,
          default_recipients: [],
          layout: false,
          helpers: [],
          subject_prefix: nil
        },
        telegram: {
          enabled: false,
          bots: [],
          open_timeout: 5,
          read_timeout: 15,
          write_timeout: 15
        }
      }
      @messages = {}
    end
  end
end
