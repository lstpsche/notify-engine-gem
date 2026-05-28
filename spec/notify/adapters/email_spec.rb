# frozen_string_literal: true

require "notify"
require "action_mailer"

ActionMailer::Base.delivery_method = :test

RSpec.describe Notify::Adapters::Email do
  let(:adapter) { described_class.new }
  let(:mock_message) { instance_double(ActionMailer::MessageDelivery, deliver_now: nil, deliver_later: nil) }

  let(:deliver_kwargs) do
    {
      message_name: :test_message,
      to: ["user@example.com"],
      subject: "Test Subject",
      locals: { key: "value" },
      template_path: "/tmp/templates/email"
    }
  end

  before do
    allow(Notify::Mailer).to receive(:dispatch).and_return(mock_message)
  end

  after do
    Notify::Mailer.layout(false)
  end

  describe "#deliver" do
    it "delegates to Notify::Mailer.dispatch" do
      adapter.deliver(**deliver_kwargs)

      expect(Notify::Mailer).to have_received(:dispatch).with(
        :test_message,
        locals: { key: "value" },
        to: ["user@example.com"],
        subject: "Test Subject",
        from: nil,
        cc: nil,
        bcc: nil,
        template_path: "/tmp/templates/email"
      )
    end

    it "arrayifies a single string recipient" do
      adapter.deliver(**deliver_kwargs.merge(to: "single@test.com"))

      expect(Notify::Mailer).to have_received(:dispatch).with(
        anything, hash_including(to: ["single@test.com"])
      )
    end

    it "passes from/cc/bcc from options to Mailer" do
      adapter.deliver(**deliver_kwargs, options: { from: "sender@test.com", cc: ["cc@test.com"], bcc: ["bcc@test.com"] })

      expect(Notify::Mailer).to have_received(:dispatch).with(
        anything, hash_including(from: "sender@test.com", cc: ["cc@test.com"], bcc: ["bcc@test.com"])
      )
    end

    it "passes nil from/cc/bcc when options omit them" do
      adapter.deliver(**deliver_kwargs, options: {})

      expect(Notify::Mailer).to have_received(:dispatch).with(
        anything, hash_including(from: nil, cc: nil, bcc: nil)
      )
    end
  end

  describe "subject prefix" do
    it "prepends a string prefix with space separator" do
      Notify.configure { |c| c.adapters[:email][:subject_prefix] = "[TEST]:" }

      adapter.deliver(**deliver_kwargs)

      expect(Notify::Mailer).to have_received(:dispatch).with(
        anything, hash_including(subject: "[TEST]: Test Subject")
      )
    end

    it "evaluates a Proc prefix and prepends result" do
      Notify.configure { |c| c.adapters[:email][:subject_prefix] = -> { "[DYNAMIC]:" } }

      adapter.deliver(**deliver_kwargs)

      expect(Notify::Mailer).to have_received(:dispatch).with(
        anything, hash_including(subject: "[DYNAMIC]: Test Subject")
      )
    end

    it "leaves subject unchanged when prefix is nil" do
      Notify.configure { |c| c.adapters[:email][:subject_prefix] = nil }

      adapter.deliver(**deliver_kwargs)

      expect(Notify::Mailer).to have_received(:dispatch).with(
        anything, hash_including(subject: "Test Subject")
      )
    end

    it "leaves subject unchanged when prefix is empty string" do
      Notify.configure { |c| c.adapters[:email][:subject_prefix] = "" }

      adapter.deliver(**deliver_kwargs)

      expect(Notify::Mailer).to have_received(:dispatch).with(
        anything, hash_including(subject: "Test Subject")
      )
    end

    it "leaves subject unchanged when prefix is whitespace-only" do
      Notify.configure { |c| c.adapters[:email][:subject_prefix] = "   " }

      adapter.deliver(**deliver_kwargs)

      expect(Notify::Mailer).to have_received(:dispatch).with(
        anything, hash_including(subject: "Test Subject")
      )
    end
  end

  describe "delivery method" do
    it "calls deliver_later by default" do
      adapter.deliver(**deliver_kwargs)

      expect(mock_message).to have_received(:deliver_later)
      expect(mock_message).not_to have_received(:deliver_now)
    end

    it "calls deliver_now when options specify :deliver_now" do
      adapter.deliver(**deliver_kwargs, options: { delivery_method: :deliver_now })

      expect(mock_message).to have_received(:deliver_now)
      expect(mock_message).not_to have_received(:deliver_later)
    end

    it "calls deliver_now when options specify string 'deliver_now'" do
      adapter.deliver(**deliver_kwargs, options: { delivery_method: "deliver_now" })

      expect(mock_message).to have_received(:deliver_now)
    end

    it "falls back to config delivery_method when options omit it" do
      Notify.configure { |c| c.adapters[:email][:delivery_method] = :deliver_now }

      adapter.deliver(**deliver_kwargs, options: {})

      expect(mock_message).to have_received(:deliver_now)
    end

    it "prefers options delivery_method over config" do
      Notify.configure { |c| c.adapters[:email][:delivery_method] = :deliver_now }

      adapter.deliver(**deliver_kwargs, options: { delivery_method: :deliver_later })

      expect(mock_message).to have_received(:deliver_later)
    end
  end

  describe "layout configuration" do
    it "sets layout on Notify::Mailer when configured" do
      Notify.configure { |c| c.adapters[:email][:layout] = "notify_mailer" }

      allow(Notify::Mailer).to receive(:layout).and_call_original

      adapter.deliver(**deliver_kwargs)

      expect(Notify::Mailer).to have_received(:layout).with("notify_mailer")
    end

    it "sets layout to false when config is false" do
      Notify.configure { |c| c.adapters[:email][:layout] = false }

      allow(Notify::Mailer).to receive(:layout).and_call_original

      adapter.deliver(**deliver_kwargs)

      expect(Notify::Mailer).to have_received(:layout).with(false)
    end

    it "sets layout to false when config is nil" do
      Notify.configure { |c| c.adapters[:email][:layout] = nil }

      allow(Notify::Mailer).to receive(:layout).and_call_original

      adapter.deliver(**deliver_kwargs)

      expect(Notify::Mailer).to have_received(:layout).with(false)
    end
  end

  describe "helpers configuration" do
    let(:helper_module) { Module.new { def test_helper; "helped"; end } }

    it "includes helper modules on Notify::Mailer" do
      Notify.configure { |c| c.adapters[:email][:helpers] = [helper_module] }

      expect(Notify::Mailer).to receive(:helper).with(helper_module).and_call_original

      adapter.deliver(**deliver_kwargs)
    end

    it "skips helpers when config is empty array" do
      Notify.configure { |c| c.adapters[:email][:helpers] = [] }

      expect(Notify::Mailer).not_to receive(:helper)

      adapter.deliver(**deliver_kwargs)
    end

    it "skips helpers when config is nil" do
      Notify.configure { |c| c.adapters[:email][:helpers] = nil }

      expect(Notify::Mailer).not_to receive(:helper)

      adapter.deliver(**deliver_kwargs)
    end
  end

  describe ".template_extensions" do
    it "returns an array of symbols" do
      extensions = described_class.template_extensions

      expect(extensions).to be_an(Array)
      expect(extensions).to all(be_a(Symbol))
    end

    it "includes format+handler combinations like html.erb" do
      extensions = described_class.template_extensions

      expect(extensions).to include(:"html.erb")
      expect(extensions).to include(:"text.erb")
    end

    it "includes bare handler extensions" do
      extensions = described_class.template_extensions

      expect(extensions).to include(:erb)
    end

    it "does not contain duplicates" do
      extensions = described_class.template_extensions

      expect(extensions).to eq(extensions.uniq)
    end
  end

  describe "contract compliance" do
    it "inherits from Notify::Adapters::Base" do
      expect(described_class.ancestors).to include(Notify::Adapters::Base)
    end

    it "implements #deliver accepting the Base contract arguments" do
      expect { adapter.deliver(**deliver_kwargs) }.not_to raise_error
    end

    it "implements .template_extensions" do
      expect { described_class.template_extensions }.not_to raise_error
    end
  end
end
