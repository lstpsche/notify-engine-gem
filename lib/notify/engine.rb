# frozen_string_literal: true

require "active_support/core_ext/module/delegation"
require "rails/engine"

module Notify
  class Engine < ::Rails::Engine
    initializer "notify_engine.autoload_paths" do |app|
      templates_path = app.root.join(Notify.config.templates_path).to_s

      app.config.autoload_paths << templates_path unless app.config.autoload_paths.include?(templates_path)
      app.config.eager_load_paths << templates_path unless app.config.eager_load_paths.include?(templates_path)
    end
  end
end
