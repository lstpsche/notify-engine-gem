# frozen_string_literal: true

require "notify"

RSpec.describe "adapter registration" do
  let(:adapter_class) { Class.new }
  let(:other_adapter_class) { Class.new }

  it "registers an adapter by symbol key" do
    Notify.register_adapter(:custom, adapter_class)

    expect(Notify.registered_adapters).to eq(custom: adapter_class)
  end

  it "normalizes string keys to symbols" do
    Notify.register_adapter("custom", adapter_class)

    expect(Notify.registered_adapters).to eq(custom: adapter_class)
  end

  it "replaces an existing adapter for the same key" do
    Notify.register_adapter(:custom, adapter_class)
    Notify.register_adapter("custom", other_adapter_class)

    expect(Notify.registered_adapters).to eq(custom: other_adapter_class)
  end

  it "returns a defensive copy of registered adapters" do
    Notify.register_adapter(:custom, adapter_class)

    adapters = Notify.registered_adapters
    adapters[:custom] = other_adapter_class

    expect(Notify.registered_adapters).to eq(custom: adapter_class)
  end

  it "can reset adapter registrations" do
    Notify.register_adapter(:custom, adapter_class)

    Notify.reset_adapters!

    expect(Notify.registered_adapters).to eq({})
  end
end
