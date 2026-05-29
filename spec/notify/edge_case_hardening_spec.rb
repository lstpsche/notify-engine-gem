# frozen_string_literal: true

require "notify"
require "fileutils"
require "tmpdir"

RSpec.describe "edge case hardening" do
  let(:logger) { Logger.new(IO::NULL) }

  def create_template(base, *path_parts)
    full_path = File.join(base, *path_parts)
    FileUtils.mkdir_p(File.dirname(full_path))
    FileUtils.touch(full_path)
  end

  def build_test_adapter
    calls = []
    adapter_class = Class.new(Notify::Adapters::Base) do
      define_method(:deliver) do |**args|
        calls << args
      end

      define_singleton_method(:template_extensions) { [:erb] }
    end
    [adapter_class, calls]
  end

  def build_failing_adapter(error_class = RuntimeError, message = "delivery failed")
    Class.new(Notify::Adapters::Base) do
      define_method(:deliver) do |**_args|
        raise error_class, message
      end

      define_singleton_method(:template_extensions) { [:erb] }
    end
  end

  before do
    allow(Rails).to receive(:logger).and_return(logger)
  end

  describe "disabled adapter still appears in introspection" do
    it "shows disabled adapter in Notify.messages and Notify.adapters but skips delivery" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "intro_disabled.html.erb")
        create_template(dir, "telegram", "intro_disabled.md.erb")
        Notify.build_registry!(dir)

        email_class, email_calls = build_test_adapter
        tg_class, tg_calls = build_test_adapter
        Notify.register_adapter(:email, email_class)
        Notify.register_adapter(:telegram, tg_class)

        Notify.configure do |c|
          c.adapters[:email][:enabled] = false
          c.adapters[:telegram][:enabled] = true
          c.messages[:intro_disabled] = { subject: "s", tg_recipients: ["bot1"] }
        end

        expect(Notify.messages[:intro_disabled]).to include(:email)
        expect(Notify.messages[:intro_disabled]).to include(:telegram)
        expect(Notify.adapters[:email]).to include(:intro_disabled)
        expect(Notify.adapters[:telegram]).to include(:intro_disabled)

        Notify.message(:intro_disabled)

        expect(tg_calls.size).to eq(1)
        expect(email_calls).to be_empty
      end
    end
  end

  describe "all adapters disabled for a message" do
    it "does not raise and makes no delivery calls (vacuous success)" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "all_disabled.html.erb")
        create_template(dir, "telegram", "all_disabled.md.erb")
        Notify.build_registry!(dir)

        email_class, email_calls = build_test_adapter
        tg_class, tg_calls = build_test_adapter
        Notify.register_adapter(:email, email_class)
        Notify.register_adapter(:telegram, tg_class)

        Notify.configure do |c|
          c.adapters[:email][:enabled] = false
          c.adapters[:telegram][:enabled] = false
          c.messages[:all_disabled] = {
            email_recipients: ["r@t.com"], subject: "s", tg_recipients: ["bot1"]
          }
        end

        expect { Notify.message(:all_disabled) }.not_to raise_error

        expect(email_calls).to be_empty
        expect(tg_calls).to be_empty
      end
    end
  end

  describe "PayloadClass method raises during per-adapter dispatch" do
    it "isolates the error per-adapter — other adapters still deliver" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "pc_method_err.html.erb")
        create_template(dir, "telegram", "pc_method_err.md.erb")
        Notify.build_registry!(dir)

        email_class, email_calls = build_test_adapter
        tg_class, tg_calls = build_test_adapter
        Notify.register_adapter(:email, email_class)
        Notify.register_adapter(:telegram, tg_class)

        payload_class = Class.new(Notify::PayloadClass) do
          subject "test subject"

          def email_recipients
            raise RuntimeError, "email_recipients exploded"
          end

          def tg_recipients
            %i[alerts_bot]
          end
        end
        stub_const("NotifyTemplates::PcMethodErr", payload_class)

        Notify.configure do |c|
          c.adapters[:telegram][:enabled] = true
        end

        expect { Notify.message(:pc_method_err) }.not_to raise_error

        expect(tg_calls.size).to eq(1)
        expect(email_calls).to be_empty
      end
    end
  end

  describe "instrumentation subscriber error isolation" do
    it "dispatch succeeds when subscriber raises for one adapter but another succeeds" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "sub_err.html.erb")
        create_template(dir, "telegram", "sub_err.md.erb")
        Notify.build_registry!(dir)

        email_class, email_calls = build_test_adapter
        tg_class, tg_calls = build_test_adapter
        Notify.register_adapter(:email, email_class)
        Notify.register_adapter(:telegram, tg_class)

        Notify.configure do |c|
          c.adapters[:telegram][:enabled] = true
          c.messages[:sub_err] = { email_recipients: ["r@t.com"], subject: "s", tg_recipients: ["bot1"] }
        end

        sub = ActiveSupport::Notifications.subscribe("notify.adapter.deliver") do |event|
          raise "subscriber explosion" if event.payload[:adapter] == :email
        end

        begin
          expect { Notify.message(:sub_err) }.not_to raise_error
          expect(tg_calls.size).to eq(1)
          expect(email_calls.size).to eq(1)
        ensure
          ActiveSupport::Notifications.unsubscribe(sub)
        end
      end
    end
  end

  describe "PayloadClass locals returns nil during full dispatch" do
    it "falls back to raw payload minus reserved keys end-to-end" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "locals_nil.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        payload_class = Class.new(Notify::PayloadClass) do
          email_recipients ["r@t.com"]
          subject "s"

          def locals
            nil
          end
        end
        stub_const("NotifyTemplates::LocalsNil", payload_class)

        Notify.message(:locals_nil, custom_data: "hello", report_id: 42, subject: "override", email_to: ["x@y.com"])

        expect(calls.size).to eq(1)
        expect(calls.first[:locals]).to eq({ custom_data: "hello", report_id: 42 })
      end
    end
  end

  describe "all enabled adapters have resolution errors" do
    it "raises DeliveryError with MissingRecipients for both adapters" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "both_missing.html.erb")
        create_template(dir, "telegram", "both_missing.md.erb")
        Notify.build_registry!(dir)

        email_class, _email_calls = build_test_adapter
        tg_class, _tg_calls = build_test_adapter
        Notify.register_adapter(:email, email_class)
        Notify.register_adapter(:telegram, tg_class)

        Notify.configure do |c|
          c.adapters[:telegram][:enabled] = true
          c.messages[:both_missing] = { subject: "s" }
        end

        expect { Notify.message(:both_missing) }
          .to raise_error(Notify::DeliveryError) { |e|
            expect(e.adapter_errors.keys).to contain_exactly(:email, :telegram)
            expect(e.adapter_errors[:email]).to be_a(Notify::MissingRecipients)
            expect(e.adapter_errors[:telegram]).to be_a(Notify::MissingRecipients)
          }
      end
    end
  end

  describe "reserved kwargs visible to PayloadClass initialize but stripped from locals" do
    it "PayloadClass receives reserved kwargs in init but default_locals strips them" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "reserved_kwargs.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        received_subject = nil

        payload_class = Class.new(Notify::PayloadClass) do
          email_recipients ["r@t.com"]

          define_method(:initialize) do |**payload|
            received_subject = payload[:subject]
            super(**payload)
          end
        end
        stub_const("NotifyTemplates::ReservedKwargs", payload_class)

        Notify.message(:reserved_kwargs, subject: "custom subject", data: "value", email_to: ["x@y.com"])

        expect(received_subject).to eq("custom subject")

        expect(calls.size).to eq(1)
        expect(calls.first[:locals]).to eq({ data: "value" })
        expect(calls.first[:locals]).not_to have_key(:subject)
        expect(calls.first[:locals]).not_to have_key(:email_to)
      end
    end
  end
end
