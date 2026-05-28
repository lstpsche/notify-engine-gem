# frozen_string_literal: true

require "notify"
require "fileutils"
require "tmpdir"

RSpec.describe "dispatch integration" do
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

  describe "full resolution priority chain (end-to-end)" do
    it "payload class instance method wins over all other levels" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "priority_chain.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        payload_class = Class.new(Notify::PayloadClass) do
          email_recipients ["dsl@test.com"]
          subject "dsl subject"

          def initialize(**payload)
            @data = payload[:data]
          end

          def email_recipients
            ["instance@test.com"]
          end

          def subject
            "instance subject"
          end
        end
        stub_const("NotifyTemplates::PriorityChain", payload_class)

        Notify.configure do |c|
          c.messages[:priority_chain] = { email_recipients: ["config@test.com"], subject: "config subject" }
          c.adapters[:email][:default_recipients] = ["global@test.com"]
        end

        Notify.message(:priority_chain, data: "value", email_to: ["inline@test.com"], subject: "inline subject")

        expect(calls.size).to eq(1)
        expect(calls.first[:to]).to eq(["instance@test.com"])
        expect(calls.first[:subject]).to eq("instance subject")
      end
    end

    it "DSL wins over inline kwargs, config, and global defaults" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "dsl_wins.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        payload_class = Class.new(Notify::PayloadClass) do
          email_recipients ["dsl@test.com"]
          subject "dsl subject"
        end
        stub_const("NotifyTemplates::DslWins", payload_class)

        Notify.configure do |c|
          c.messages[:dsl_wins] = { email_recipients: ["config@test.com"], subject: "config subject" }
          c.adapters[:email][:default_recipients] = ["global@test.com"]
        end

        Notify.message(:dsl_wins, email_to: ["inline@test.com"], subject: "inline subject")

        expect(calls.first[:to]).to eq(["dsl@test.com"])
        expect(calls.first[:subject]).to eq("dsl subject")
      end
    end

    it "inline kwargs win over per-message config and global defaults" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "inline_wins.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:inline_wins] = { email_recipients: ["config@test.com"], subject: "config subject" }
          c.adapters[:email][:default_recipients] = ["global@test.com"]
        end

        Notify.message(:inline_wins, email_to: ["inline@test.com"], subject: "inline subject")

        expect(calls.first[:to]).to eq(["inline@test.com"])
        expect(calls.first[:subject]).to eq("inline subject")
      end
    end

    it "per-message config wins over global adapter defaults" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "config_wins.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:config_wins] = { email_recipients: ["config@test.com"], subject: "config subject" }
          c.adapters[:email][:default_recipients] = ["global@test.com"]
        end

        Notify.message(:config_wins)

        expect(calls.first[:to]).to eq(["config@test.com"])
        expect(calls.first[:subject]).to eq("config subject")
      end
    end

    it "global adapter defaults are used as last resort" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "global_fallback.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:global_fallback] = { subject: "s" }
          c.adapters[:email][:default_recipients] = ["global@test.com"]
        end

        Notify.message(:global_fallback)

        expect(calls.first[:to]).to eq(["global@test.com"])
      end
    end
  end

  describe "multi-adapter dispatch — one fails, one succeeds" do
    it "does not raise and delivers to the successful adapter" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "partial.html.erb")
        create_template(dir, "telegram", "partial.md.erb")
        Notify.build_registry!(dir)

        email_class, email_calls = build_test_adapter
        tg_class = build_failing_adapter(RuntimeError, "tg exploded")
        Notify.register_adapter(:email, email_class)
        Notify.register_adapter(:telegram, tg_class)

        Notify.configure do |c|
          c.adapters[:telegram][:enabled] = true
          c.messages[:partial] = { email_recipients: ["e@t.com"], subject: "s", tg_recipients: ["bot1"] }
        end

        expect { Notify.message(:partial) }.not_to raise_error
        expect(email_calls.size).to eq(1)
        expect(email_calls.first[:message_name]).to eq(:partial)
      end
    end

    it "emits notify.adapter.error for the failing adapter" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "partial_ev.html.erb")
        create_template(dir, "telegram", "partial_ev.md.erb")
        Notify.build_registry!(dir)

        email_class, _email_calls = build_test_adapter
        tg_class = build_failing_adapter(RuntimeError, "tg exploded")
        Notify.register_adapter(:email, email_class)
        Notify.register_adapter(:telegram, tg_class)

        Notify.configure do |c|
          c.adapters[:telegram][:enabled] = true
          c.messages[:partial_ev] = { email_recipients: ["e@t.com"], subject: "s", tg_recipients: ["bot1"] }
        end

        events = []
        sub = ActiveSupport::Notifications.subscribe("notify.adapter.error") { |event| events << event }

        Notify.message(:partial_ev)

        ActiveSupport::Notifications.unsubscribe(sub)

        expect(events.size).to eq(1)
        expect(events.first.payload[:adapter]).to eq(:telegram)
        expect(events.first.payload[:error].message).to eq("tg exploded")
      end
    end
  end

  describe "all adapters fail — DeliveryError" do
    it "raises DeliveryError with adapter_errors hash containing all failures" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "all_fail.html.erb")
        create_template(dir, "telegram", "all_fail.md.erb")
        Notify.build_registry!(dir)

        email_class = build_failing_adapter(RuntimeError, "email boom")
        tg_class = build_failing_adapter(RuntimeError, "tg boom")
        Notify.register_adapter(:email, email_class)
        Notify.register_adapter(:telegram, tg_class)

        Notify.configure do |c|
          c.adapters[:telegram][:enabled] = true
          c.messages[:all_fail] = { email_recipients: ["r@t.com"], subject: "s", tg_recipients: ["bot1"] }
        end

        expect { Notify.message(:all_fail) }
          .to raise_error(Notify::DeliveryError) { |e|
            expect(e.adapter_errors.keys).to contain_exactly(:email, :telegram)
            expect(e.adapter_errors[:email].message).to eq("email boom")
            expect(e.adapter_errors[:telegram].message).to eq("tg boom")
            expect(e.message).to include("All adapters failed")
          }
      end
    end
  end

  describe "unknown message raises UnknownMessage" do
    it "raises Notify::UnknownMessage for a message not in the registry" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "exists.html.erb")
        Notify.build_registry!(dir)

        expect { Notify.message(:nonexistent) }
          .to raise_error(Notify::UnknownMessage, /nonexistent/)
      end
    end
  end

  describe "missing recipients — MissingRecipients caught per-adapter" do
    it "catches MissingRecipients and continues to other adapters" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "no_recip.html.erb")
        create_template(dir, "telegram", "no_recip.md.erb")
        Notify.build_registry!(dir)

        email_class, _email_calls = build_test_adapter
        tg_class, tg_calls = build_test_adapter
        Notify.register_adapter(:email, email_class)
        Notify.register_adapter(:telegram, tg_class)

        Notify.configure do |c|
          c.adapters[:email][:default_recipients] = []
          c.adapters[:telegram][:enabled] = true
          c.messages[:no_recip] = { subject: "s", tg_recipients: ["bot1"] }
        end

        expect { Notify.message(:no_recip) }.not_to raise_error
        expect(tg_calls.size).to eq(1)
      end
    end
  end

  describe "missing subject — MissingSubject caught per-adapter (email-specific)" do
    it "catches MissingSubject for email and still delivers to telegram" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "no_subj.html.erb")
        create_template(dir, "telegram", "no_subj.md.erb")
        Notify.build_registry!(dir)

        email_class, _email_calls = build_test_adapter
        tg_class, tg_calls = build_test_adapter
        Notify.register_adapter(:email, email_class)
        Notify.register_adapter(:telegram, tg_class)

        Notify.configure do |c|
          c.adapters[:email][:default_recipients] = ["r@t.com"]
          c.adapters[:telegram][:enabled] = true
          c.messages[:no_subj] = { tg_recipients: ["bot1"] }
        end

        expect { Notify.message(:no_subj) }.not_to raise_error
        expect(tg_calls.size).to eq(1)
      end
    end
  end

  describe "disabled adapter is skipped" do
    it "does not call deliver on a disabled adapter" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "disabled_test.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.adapters[:email][:enabled] = false
          c.messages[:disabled_test] = { email_recipients: ["r@t.com"], subject: "s" }
        end

        expect { Notify.message(:disabled_test) }.not_to raise_error
        expect(calls).to be_empty
      end
    end
  end

  describe "instrumentation events" do
    it "emits notify.message.dispatch with message_name and adapters" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "ev_dispatch.html.erb")
        Notify.build_registry!(dir)

        adapter_class, _calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:ev_dispatch] = { email_recipients: ["r@t.com"], subject: "s" }
        end

        events = []
        sub = ActiveSupport::Notifications.subscribe("notify.message.dispatch") { |event| events << event }

        Notify.message(:ev_dispatch)

        ActiveSupport::Notifications.unsubscribe(sub)

        expect(events.size).to eq(1)
        expect(events.first.payload[:message_name]).to eq(:ev_dispatch)
        expect(events.first.payload[:adapters]).to eq([:email])
      end
    end

    it "emits notify.adapter.deliver per adapter with message_name, adapter, and to" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "ev_deliver.html.erb")
        create_template(dir, "telegram", "ev_deliver.md.erb")
        Notify.build_registry!(dir)

        email_class, _email_calls = build_test_adapter
        tg_class, _tg_calls = build_test_adapter
        Notify.register_adapter(:email, email_class)
        Notify.register_adapter(:telegram, tg_class)

        Notify.configure do |c|
          c.adapters[:telegram][:enabled] = true
          c.messages[:ev_deliver] = { email_recipients: ["e@t.com"], subject: "s", tg_recipients: ["bot1"] }
        end

        events = []
        sub = ActiveSupport::Notifications.subscribe("notify.adapter.deliver") { |event| events << event }

        Notify.message(:ev_deliver)

        ActiveSupport::Notifications.unsubscribe(sub)

        expect(events.size).to eq(2)
        adapter_names = events.map { |e| e.payload[:adapter] }
        expect(adapter_names).to contain_exactly(:email, :telegram)
      end
    end

    it "emits notify.adapter.error on failure with message_name, adapter, and error" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "ev_error.html.erb")
        Notify.build_registry!(dir)

        failing_class = build_failing_adapter(RuntimeError, "kaboom")
        Notify.register_adapter(:email, failing_class)

        Notify.configure do |c|
          c.messages[:ev_error] = { email_recipients: ["r@t.com"], subject: "s" }
        end

        events = []
        sub = ActiveSupport::Notifications.subscribe("notify.adapter.error") { |event| events << event }

        expect { Notify.message(:ev_error) }.to raise_error(Notify::DeliveryError)

        ActiveSupport::Notifications.unsubscribe(sub)

        expect(events.size).to eq(1)
        expect(events.first.payload[:message_name]).to eq(:ev_error)
        expect(events.first.payload[:adapter]).to eq(:email)
        expect(events.first.payload[:error]).to be_a(RuntimeError)
      end
    end
  end

  describe "no payload class — raw payload mode" do
    it "uses raw payload minus reserved keys as locals" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "raw_mode.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:raw_mode] = { email_recipients: ["r@t.com"], subject: "s" }
        end

        Notify.message(:raw_mode, custom_data: "hello", report_id: 42, subject: "override", email_to: ["x@y.com"])

        expect(calls.first[:locals]).to eq({ custom_data: "hello", report_id: 42 })
      end
    end

    it "resolves recipients from inline kwargs when no payload class" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "raw_inline.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.message(:raw_inline, email_to: ["inline@t.com"], subject: "s", data: "val")

        expect(calls.first[:to]).to eq(["inline@t.com"])
        expect(calls.first[:subject]).to eq("s")
        expect(calls.first[:locals]).to eq({ data: "val" })
      end
    end
  end

  describe "payload class initialization error — graceful fallback" do
    it "falls back to raw payload mode and logs a warning" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "init_error.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        payload_class = Class.new(Notify::PayloadClass) do
          def initialize(**_payload)
            raise "init explosion"
          end
        end
        stub_const("NotifyTemplates::InitError", payload_class)

        Notify.configure do |c|
          c.messages[:init_error] = { email_recipients: ["r@t.com"], subject: "fallback subject" }
        end

        expect(logger).to receive(:warn).with(/PayloadClass.*failed to initialize.*init explosion/)

        Notify.message(:init_error, data: "raw")

        expect(calls.size).to eq(1)
        expect(calls.first[:to]).to eq(["r@t.com"])
        expect(calls.first[:subject]).to eq("fallback subject")
        expect(calls.first[:locals]).to eq({ data: "raw" })
      end
    end
  end

  describe "telegram recipient resolution (architecture-only)" do
    it "resolves tg_recipients from payload class for telegram adapter" do
      Dir.mktmpdir do |dir|
        create_template(dir, "telegram", "tg_test.md.erb")
        Notify.build_registry!(dir)

        tg_class, calls = build_test_adapter
        Notify.register_adapter(:telegram, tg_class)

        payload_class = Class.new(Notify::PayloadClass) do
          tg_recipients %i[alerts_bot notifier]
        end
        stub_const("NotifyTemplates::TgTest", payload_class)

        Notify.configure do |c|
          c.adapters[:telegram][:enabled] = true
        end

        Notify.message(:tg_test)

        expect(calls.size).to eq(1)
        expect(calls.first[:to]).to eq(%i[alerts_bot notifier])
        expect(calls.first[:subject]).to be_nil
      end
    end

    it "resolves tg_recipients from config when no payload class" do
      Dir.mktmpdir do |dir|
        create_template(dir, "telegram", "tg_config.md.erb")
        Notify.build_registry!(dir)

        tg_class, calls = build_test_adapter
        Notify.register_adapter(:telegram, tg_class)

        Notify.configure do |c|
          c.adapters[:telegram][:enabled] = true
          c.messages[:tg_config] = { tg_recipients: ["default_bot"] }
        end

        Notify.message(:tg_config, data: "payload")

        expect(calls.size).to eq(1)
        expect(calls.first[:to]).to eq(["default_bot"])
        expect(calls.first[:locals]).to eq({ data: "payload" })
      end
    end
  end

  describe "custom adapter uses convention-based method names" do
    it "resolves recipients via :<adapter>_recipients method on payload class" do
      Dir.mktmpdir do |dir|
        create_template(dir, "slack", "custom_msg.md.erb")
        Notify.build_registry!(dir)

        slack_class, calls = build_test_adapter
        Notify.register_adapter(:slack, slack_class)

        payload_class = Class.new(Notify::PayloadClass) do
          def slack_recipients
            ["#general", "#alerts"]
          end
        end
        stub_const("NotifyTemplates::CustomMsg", payload_class)

        Notify.message(:custom_msg)

        expect(calls.size).to eq(1)
        expect(calls.first[:to]).to eq(["#general", "#alerts"])
      end
    end
  end

  describe "full pipeline verification" do
    it "passes all expected arguments to the adapter deliver method" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "full_verify.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        payload_class = Class.new(Notify::PayloadClass) do
          email_recipients ["user@test.com"]
          subject "Test Subject"
          locals { { computed: true, ts: "now" } }

          def email_from
            "sender@test.com"
          end
        end
        stub_const("NotifyTemplates::FullVerify", payload_class)

        Notify.message(:full_verify, raw_data: "ignored")

        expect(calls.size).to eq(1)
        call = calls.first
        expect(call[:message_name]).to eq(:full_verify)
        expect(call[:to]).to eq(["user@test.com"])
        expect(call[:subject]).to eq("Test Subject")
        expect(call[:locals]).to eq({ computed: true, ts: "now" })
        expect(call[:template_path]).to eq(Pathname(dir).join("email"))
        expect(call[:options][:from]).to eq("sender@test.com")
      end
    end
  end
end
