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

    initializer "notify_engine.register_adapters" do
      Notify.register_adapter(:email, Notify::Adapters::Email)
    end

    initializer "notify_engine.registry" do |app|
      app.config.to_prepare do
        Notify.build_registry!(app.root.join(Notify.config.templates_path))
      end
    end

    initializer "notify_engine.freeze_registry" do |app|
      app.config.after_initialize do
        Notify.registry&.freeze! if Rails.env.production?
      end
    end

    initializer "notify_engine.test_mode", after: "notify_engine.registry" do
      Notify.test_mode! if Rails.env.test?
    end
  end
end
