# frozen_string_literal: true

require "action_view"
require "set"

module Notify
  class Registry
    def initialize(templates_path)
      @templates_path = Pathname(templates_path)
      @message_adapters = {}
      scan! if @templates_path.directory?
    end

    def messages
      @messages ||= build_messages_view
    end

    def adapters
      @adapters_view ||= build_adapters_view
    end

    def message?(name)
      @message_adapters.key?(name.to_sym)
    end

    def adapters_for(message_name)
      set = @message_adapters[message_name.to_sym]
      return [].freeze unless set

      set.to_a.sort.freeze
    end

    def freeze!
      @message_adapters.each_value(&:freeze)
      @message_adapters.freeze
      messages
      adapters
      self
    end

    def frozen?
      @message_adapters.frozen?
    end

    private

    def scan!
      handler_extensions = ActionView::Template::Handlers.extensions

      @templates_path.children.select(&:directory?).each do |adapter_dir|
        adapter_key = adapter_dir.basename.to_s.to_sym

        adapter_dir.children.select { |entry| entry.file? }.each do |template_file|
          basename = template_file.basename.to_s
          next if basename.start_with?("_")

          message_name = extract_message_name(basename, handler_extensions)
          next unless message_name

          @message_adapters[message_name] ||= Set.new
          @message_adapters[message_name] << adapter_key
        end
      end
    end

    def extract_message_name(filename, handler_extensions)
      parts = filename.split(".")
      return nil if parts.size < 2

      handler = parts.last.to_sym
      return nil unless handler_extensions.include?(handler)

      parts.pop
      parts.pop if parts.size > 1

      parts.join(".").to_sym
    end

    def build_messages_view
      result = {}
      @message_adapters.keys.sort.each do |msg|
        result[msg] = @message_adapters[msg].to_a.sort.freeze
      end
      result.freeze
    end

    def build_adapters_view
      inverted = {}
      @message_adapters.each do |msg, adapter_set|
        adapter_set.each do |adapter|
          inverted[adapter] ||= []
          inverted[adapter] << msg
        end
      end

      result = {}
      inverted.keys.sort.each do |adapter|
        result[adapter] = inverted[adapter].sort.freeze
      end
      result.freeze
    end
  end
end
