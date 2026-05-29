# frozen_string_literal: true

require "notify"
require "fileutils"
require "tmpdir"
require "action_mailer"

ActionMailer::Base.delivery_method = :test
ActiveJob::Base.queue_adapter = :inline

RSpec.describe "test mode integration" do
  include Notify::TestHelper

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

  before do
    allow(Rails).to receive(:logger).and_return(logger)
    Notify.test_mode!
    ActionMailer::Base.deliveries.clear
  end

  describe "basic capture cycle" do
    it "captures delivery with correct hash structure" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "basic_capture.html.erb")
        Notify.build_registry!(dir)

        adapter_class, _calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:basic_capture] = { email_recipients: ["user@test.com"], subject: "Hello" }
        end

        Notify.message(:basic_capture, report: "data", count: 3)

        expect(Notify.deliveries.size).to eq(1)

        delivery = Notify.deliveries.first
        expect(delivery[:name]).to eq(:basic_capture)
        expect(delivery[:adapters]).to eq([:email])
        expect(delivery[:payload]).to eq({ report: "data", count: 3 })
        expect(delivery[:resolved][:subject]).to eq("Hello")
        expect(delivery[:resolved][:recipients]).to eq({ email: ["user@test.com"] })
        expect(delivery[:resolved][:locals]).to eq({ report: "data", count: 3 })
      end
    end
  end

  describe "multiple dispatches accumulate" do
    it "captures all dispatches in deliveries array" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "multi_one.html.erb")
        create_template(dir, "email", "multi_two.html.erb")
        create_template(dir, "email", "multi_three.html.erb")
        Notify.build_registry!(dir)

        adapter_class, _calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:multi_one] = { email_recipients: ["u@t.com"], subject: "S1" }
          c.messages[:multi_two] = { email_recipients: ["u@t.com"], subject: "S2" }
          c.messages[:multi_three] = { email_recipients: ["u@t.com"], subject: "S3" }
        end

        Notify.message(:multi_one, data: "a")
        Notify.message(:multi_two, data: "b")
        Notify.message(:multi_three, data: "c")

        expect(Notify.deliveries.size).to eq(3)
        expect(Notify.deliveries.map { |d| d[:name] }).to eq(%i[multi_one multi_two multi_three])
      end
    end
  end

  describe "deliveries cleared between examples" do
    context "with shared setup" do
      before do
        Dir.mktmpdir do |dir|
          create_template(dir, "email", "clear_test.html.erb")
          Notify.build_registry!(dir)

          adapter_class, _calls = build_test_adapter
          Notify.register_adapter(:email, adapter_class)

          Notify.configure do |c|
            c.messages[:clear_test] = { email_recipients: ["u@t.com"], subject: "S" }
          end

          Notify.message(:clear_test, data: "fresh")
        end
      end

      it "only contains the dispatch from this example" do
        expect(Notify.deliveries.size).to eq(1)
        expect(Notify.deliveries.first[:name]).to eq(:clear_test)
      end

      it "does not contain dispatches from other examples" do
        expect(Notify.deliveries.size).to eq(1)
      end
    end
  end

  describe "TestHelper assertions — happy path" do
    it "assert_notify_dispatched passes with correct count and recipients" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "helper_happy.html.erb")
        Notify.build_registry!(dir)

        adapter_class, _calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:helper_happy] = { email_recipients: ["user@test.com"], subject: "Hi" }
        end

        Notify.message(:helper_happy, data: "v")

        expect { assert_notify_dispatched(:helper_happy, count: 1) }.not_to raise_error
        expect { assert_notify_dispatched(:helper_happy, to: ["user@test.com"]) }.not_to raise_error
      end
    end
  end

  describe "TestHelper assertions — failure case" do
    it "raises with descriptive error when no matching dispatch exists" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "exists.html.erb")
        Notify.build_registry!(dir)

        adapter_class, _calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:exists] = { email_recipients: ["u@t.com"], subject: "S" }
        end

        Notify.message(:exists, data: "v")

        expect { assert_notify_dispatched(:nonexistent) }
          .to raise_error(RuntimeError, /Expected Notify.message\(:nonexistent\) to have been dispatched/)
      end
    end
  end

  describe "last_notify_delivery" do
    it "returns the most recent dispatch" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "last_first.html.erb")
        create_template(dir, "email", "last_second.html.erb")
        Notify.build_registry!(dir)

        adapter_class, _calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:last_first] = { email_recipients: ["u@t.com"], subject: "S1" }
          c.messages[:last_second] = { email_recipients: ["u@t.com"], subject: "S2" }
        end

        Notify.message(:last_first, data: "a")
        Notify.message(:last_second, data: "b")

        expect(last_notify_delivery[:name]).to eq(:last_second)
      end
    end
  end

  describe "UnknownMessage still raises in test mode" do
    it "raises Notify::UnknownMessage for unregistered messages" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "known.html.erb")
        Notify.build_registry!(dir)

        expect { Notify.message(:unknown_msg) }
          .to raise_error(Notify::UnknownMessage, /unknown_msg/)
      end
    end
  end

  describe "multi-adapter capture" do
    it "captures recipients keyed by adapter for all enabled adapters" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "multi_adapt.html.erb")
        create_template(dir, "telegram", "multi_adapt.md.erb")
        Notify.build_registry!(dir)

        email_class, _email_calls = build_test_adapter
        tg_class, _tg_calls = build_test_adapter
        Notify.register_adapter(:email, email_class)
        Notify.register_adapter(:telegram, tg_class)

        Notify.configure do |c|
          c.adapters[:telegram][:enabled] = true
          c.messages[:multi_adapt] = {
            email_recipients: ["e@test.com"],
            subject: "Multi",
            tg_recipients: ["alerts_bot"]
          }
        end

        Notify.message(:multi_adapt, data: "payload")

        delivery = Notify.deliveries.first
        expect(delivery[:adapters]).to contain_exactly(:email, :telegram)
        expect(delivery[:resolved][:recipients][:email]).to eq(["e@test.com"])
        expect(delivery[:resolved][:recipients][:telegram]).to eq(["alerts_bot"])
      end
    end
  end

  describe "PayloadClass resolution in test mode" do
    it "resolves subject, recipients, and locals from the payload class" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "pc_integ.html.erb")
        Notify.build_registry!(dir)

        adapter_class, _calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        payload_class = Class.new(Notify::PayloadClass) do
          email_recipients ["pc@test.com"]

          def initialize(**payload)
            @items = payload[:items]
          end

          def subject
            "#{@items.size} items found"
          end

          def locals
            { items: @items, generated_at: "2026-05-29" }
          end
        end
        stub_const("NotifyTemplates::PcInteg", payload_class)

        Notify.message(:pc_integ, items: %w[a b c])

        delivery = Notify.deliveries.first
        expect(delivery[:resolved][:subject]).to eq("3 items found")
        expect(delivery[:resolved][:recipients]).to eq({ email: ["pc@test.com"] })
        expect(delivery[:resolved][:locals]).to eq({ items: %w[a b c], generated_at: "2026-05-29" })
      end
    end
  end

  describe "resolution error captured per-adapter" do
    it "captures MissingRecipients for email without propagating" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "err_integ.html.erb")
        create_template(dir, "telegram", "err_integ.md.erb")
        Notify.build_registry!(dir)

        email_class, _email_calls = build_test_adapter
        tg_class, _tg_calls = build_test_adapter
        Notify.register_adapter(:email, email_class)
        Notify.register_adapter(:telegram, tg_class)

        Notify.configure do |c|
          c.adapters[:telegram][:enabled] = true
          c.messages[:err_integ] = { tg_recipients: ["bot1"] }
        end

        expect { Notify.message(:err_integ, data: "v") }.not_to raise_error

        delivery = Notify.deliveries.first
        expect(delivery[:errors][:email]).to be_a(Notify::MissingRecipients)
        expect(delivery[:resolved][:recipients]).to have_key(:telegram)
        expect(delivery[:resolved][:recipients]).not_to have_key(:email)
        expect(delivery[:resolved][:recipients][:telegram]).to eq(["bot1"])
      end
    end
  end

  describe "test mode does not call real adapters" do
    it "does not send real email via ActionMailer" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "no_real_send.html.erb")
        Notify.build_registry!(dir)

        Notify.register_adapter(:email, Notify::Adapters::Email)

        Notify.configure do |c|
          c.adapters[:email][:from] = "sender@test.com"
          c.messages[:no_real_send] = { email_recipients: ["user@test.com"], subject: "Should not send" }
        end

        Notify.message(:no_real_send, data: "payload")

        expect(ActionMailer::Base.deliveries).to be_empty
        expect(Notify.deliveries.size).to eq(1)
        expect(Notify.deliveries.first[:name]).to eq(:no_real_send)
      end
    end
  end

  describe "disabled adapter skipped in test mode" do
    it "excludes disabled adapter from capture" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "disabled_cap.html.erb")
        Notify.build_registry!(dir)

        adapter_class, _calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.adapters[:email][:enabled] = false
          c.messages[:disabled_cap] = { email_recipients: ["u@t.com"], subject: "S" }
        end

        Notify.message(:disabled_cap, data: "v")

        delivery = Notify.deliveries.first
        expect(delivery[:adapters]).to be_empty
      end
    end
  end

  describe "config-only message (no payload class) in test mode" do
    it "resolves from config and strips reserved keys from locals" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "config_only.html.erb")
        Notify.build_registry!(dir)

        adapter_class, _calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:config_only] = { email_recipients: ["config@test.com"], subject: "Config Subject" }
        end

        Notify.message(:config_only, report_id: 99, extra: "info", subject: "Inline Override")

        delivery = Notify.deliveries.first
        expect(delivery[:resolved][:subject]).to eq("Inline Override")
        expect(delivery[:resolved][:recipients]).to eq({ email: ["config@test.com"] })
        expect(delivery[:resolved][:locals]).to eq({ report_id: 99, extra: "info" })
      end
    end
  end

  describe "engine initializer auto-activates test mode" do
    it "defines notify_engine.test_mode initializer" do
      initializer = Notify::Engine.initializers.find { |i| i.name == "notify_engine.test_mode" }

      expect(initializer).not_to be_nil
    end

    it "test_mode initializer runs after registry initializer" do
      names = Notify::Engine.initializers.map(&:name)
      registry_idx = names.index("notify_engine.registry")
      test_mode_idx = names.index("notify_engine.test_mode")

      expect(test_mode_idx).to be > registry_idx
    end

    it "calls Notify.test_mode! when Rails.env.test?" do
      Notify.reset_test_mode!
      expect(Notify.test_mode?).to be false

      env = double("env", test?: true, production?: false)
      allow(Rails).to receive(:env).and_return(env)

      initializer = Notify::Engine.initializers.find { |i| i.name == "notify_engine.test_mode" }
      initializer.run(double("app"))

      expect(Notify.test_mode?).to be true
    end
  end
end
