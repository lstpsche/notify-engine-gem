# frozen_string_literal: true

require "pathname"
require "notify"

RSpec.describe Notify::Engine do
  LightweightConfig = Struct.new(:autoload_paths, :eager_load_paths)
  LightweightApp = Struct.new(:root, :config)

  let(:root) { Pathname.new("/tmp/notify_engine_host") }
  let(:app_config) { LightweightConfig.new([], []) }
  let(:app) { LightweightApp.new(root, app_config) }
  let(:initializer) do
    described_class.initializers.find { |candidate| candidate.name == "notify_engine.autoload_paths" }
  end

  it "inherits from Rails::Engine" do
    expect(described_class).to be < Rails::Engine
  end

  it "adds the default notify templates path to autoload and eager-load paths" do
    initializer.run(app)

    expected_path = root.join("app/notify_templates").to_s
    expect(app.config.autoload_paths).to eq([expected_path])
    expect(app.config.eager_load_paths).to eq([expected_path])
  end

  it "uses the configured notify templates path" do
    Notify.configure do |config|
      config.templates_path = "custom/notifications"
    end

    initializer.run(app)

    expected_path = root.join("custom/notifications").to_s
    expect(app.config.autoload_paths).to eq([expected_path])
    expect(app.config.eager_load_paths).to eq([expected_path])
  end

  describe "notify_engine.register_adapters initializer" do
    let(:register_initializer) do
      described_class.initializers.find { |candidate| candidate.name == "notify_engine.register_adapters" }
    end

    it "registers Notify::Adapters::Email as the :email adapter" do
      register_initializer.run(app)

      expect(Notify.registered_adapters[:email]).to eq(Notify::Adapters::Email)
    end

    it "is defined before the registry initializer" do
      names = described_class.initializers.map(&:name)
      register_idx = names.index("notify_engine.register_adapters")
      registry_idx = names.index("notify_engine.registry")

      expect(register_idx).to be < registry_idx
    end
  end

  it "does not duplicate paths when the initializer runs more than once" do
    initializer.run(app)
    initializer.run(app)

    expected_path = root.join("app/notify_templates").to_s
    expect(app.config.autoload_paths).to eq([expected_path])
    expect(app.config.eager_load_paths).to eq([expected_path])
  end
end
