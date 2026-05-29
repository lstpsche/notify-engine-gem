# frozen_string_literal: true

require "notify"

RSpec.describe Notify do
  it "exposes the version" do
    expect(described_class::VERSION).to eq("0.1.1")
  end

  it "defines the custom error hierarchy" do
    expect(described_class::UnknownMessage).to be < described_class::Error
    expect(described_class::MissingRecipients).to be < described_class::Error
    expect(described_class::MissingSubject).to be < described_class::Error
    expect(described_class::DeliveryError).to be < described_class::Error
    expect(described_class::AdapterNotRegistered).to be < described_class::Error
    expect(described_class::NotImplementedError).to be < described_class::Error
  end
end
