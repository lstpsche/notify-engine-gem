# frozen_string_literal: true

require "notify"

RSpec.describe "notification configuration and adapter registration" do
  it "loads the public entrypoint with config, adapter registration, errors, and engine" do
    adapter_class = Class.new

    Notify.configure do |config|
      config.templates_path = "custom/notify_templates"
      config.adapters[:email][:helpers] << :helper
      config.messages[:stuck_pg_jobs] = { subject: "Stuck PgJobs detected" }
    end
    Notify.register_adapter(:custom, adapter_class)

    expect(Notify::VERSION).to eq("0.2.0")
    expect(Notify::Error).to be < StandardError
    expect(Notify.config.templates_path).to eq("custom/notify_templates")
    expect(Notify.config.adapters[:email][:helpers]).to eq([:helper])
    expect(Notify.config.messages[:stuck_pg_jobs]).to eq(subject: "Stuck PgJobs detected")
    expect(Notify.registered_adapters).to eq(custom: adapter_class)
    expect(Notify::Engine).to be < Rails::Engine
  end
end
