# frozen_string_literal: true

require "notify"
require "fileutils"
require "tmpdir"

RSpec.describe Notify::Dispatcher do
  let(:dispatcher) { described_class.new }
  let(:logger) { Logger.new(IO::NULL) }

  def create_template(base, *path_parts)
    full_path = File.join(base, *path_parts)
    FileUtils.mkdir_p(File.dirname(full_path))
    FileUtils.touch(full_path)
  end

  def build_test_adapter
    calls = []
    adapter_class = Class.new do
      define_method(:deliver) do |**args|
        calls << args
      end
    end
    [adapter_class, calls]
  end

  def build_failing_adapter(error_class = RuntimeError, message = "delivery failed")
    Class.new do
      define_method(:deliver) do |**_args|
        raise error_class, message
      end
    end
  end

  before do
    allow(Rails).to receive(:logger).and_return(logger)
  end

  describe "message validation" do
    it "raises UnknownMessage for an unknown message name" do
      Dir.mktmpdir do |dir|
        Notify.build_registry!(dir)

        expect { dispatcher.dispatch(:nonexistent) }
          .to raise_error(Notify::UnknownMessage, /nonexistent/)
      end
    end

    it "raises UnknownMessage when registry is nil" do
      Notify.reset_registry!

      expect { dispatcher.dispatch(:anything) }
        .to raise_error(Notify::UnknownMessage)
    end
  end

  describe "payload class resolution" do
    it "resolves an existing PayloadClass subclass" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "test_msg.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        payload_class = Class.new(Notify::PayloadClass) do
          email_recipients ["from_class@test.com"]
          subject "class subject"
        end
        stub_const("NotifyTemplates::TestMsg", payload_class)

        dispatcher.dispatch(:test_msg)

        expect(calls.first[:to]).to eq(["from_class@test.com"])
        expect(calls.first[:subject]).to eq("class subject")
      end
    end

    it "falls back to nil when no payload class exists" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "no_class.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:no_class] = { email_recipients: ["config@test.com"], subject: "config subject" }
        end

        dispatcher.dispatch(:no_class)

        expect(calls.first[:to]).to eq(["config@test.com"])
      end
    end

    it "falls back to nil when constant exists but is not a PayloadClass subclass" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "not_payload.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        stub_const("NotifyTemplates::NotPayload", Class.new)

        Notify.configure do |c|
          c.messages[:not_payload] = { email_recipients: ["fallback@test.com"], subject: "fallback" }
        end

        dispatcher.dispatch(:not_payload)

        expect(calls.first[:to]).to eq(["fallback@test.com"])
      end
    end

    it "falls back to nil and logs when PayloadClass#initialize raises" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "raises_init.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        payload_class = Class.new(Notify::PayloadClass) do
          def initialize(**_payload)
            raise "init explosion"
          end
        end
        stub_const("NotifyTemplates::RaisesInit", payload_class)

        Notify.configure do |c|
          c.messages[:raises_init] = { email_recipients: ["safe@test.com"], subject: "safe" }
        end

        expect(logger).to receive(:warn).with(/PayloadClass.*failed to initialize.*init explosion/)
        dispatcher.dispatch(:raises_init)

        expect(calls.first[:to]).to eq(["safe@test.com"])
      end
    end
  end

  describe "adapter-enabled filtering" do
    it "delivers to adapters that have templates, registered class, and are enabled" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "multi.html.erb")
        create_template(dir, "telegram", "multi.md.erb")
        Notify.build_registry!(dir)

        email_class, email_calls = build_test_adapter
        tg_class, tg_calls = build_test_adapter
        Notify.register_adapter(:email, email_class)
        Notify.register_adapter(:telegram, tg_class)

        Notify.configure do |c|
          c.adapters[:email][:enabled] = true
          c.adapters[:telegram][:enabled] = true
          c.messages[:multi] = { email_recipients: ["e@t.com"], subject: "s", tg_recipients: ["bot"] }
        end

        dispatcher.dispatch(:multi)

        expect(email_calls.size).to eq(1)
        expect(tg_calls.size).to eq(1)
      end
    end

    it "skips adapters with templates but no registered class and logs warning" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "orphan.html.erb")
        create_template(dir, "slack", "orphan.md.erb")
        Notify.build_registry!(dir)

        email_class, email_calls = build_test_adapter
        Notify.register_adapter(:email, email_class)

        Notify.configure do |c|
          c.messages[:orphan] = { email_recipients: ["e@t.com"], subject: "s" }
        end

        expect(logger).to receive(:warn).with(/Adapter :slack.*no registered class/)
        dispatcher.dispatch(:orphan)

        expect(email_calls.size).to eq(1)
      end
    end

    it "skips adapters where config enabled is false" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "disabled.html.erb")
        Notify.build_registry!(dir)

        email_class, email_calls = build_test_adapter
        Notify.register_adapter(:email, email_class)

        Notify.configure do |c|
          c.adapters[:email][:enabled] = false
          c.messages[:disabled] = { email_recipients: ["e@t.com"], subject: "s" }
        end

        expect { dispatcher.dispatch(:disabled) }.not_to raise_error
        expect(email_calls).to be_empty
      end
    end

    it "includes adapters with no config entry (defaults enabled: true)" do
      Dir.mktmpdir do |dir|
        create_template(dir, "custom", "no_cfg.html.erb")
        Notify.build_registry!(dir)

        custom_class, custom_calls = build_test_adapter
        Notify.register_adapter(:custom, custom_class)

        dispatcher.dispatch(:no_cfg, to: ["u@t.com"])

        expect(custom_calls.size).to eq(1)
      end
    end
  end

  describe "recipient resolution (5-level chain)" do
    it "L1: payload class instance method wins over all" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "recip_l1.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        payload_class = Class.new(Notify::PayloadClass) do
          email_recipients ["dsl@test.com"]
          subject "s"

          def email_recipients
            ["instance@test.com"]
          end
        end
        stub_const("NotifyTemplates::RecipL1", payload_class)

        Notify.configure do |c|
          c.messages[:recip_l1] = { email_recipients: ["config@test.com"], subject: "s" }
          c.adapters[:email][:default_recipients] = ["global@test.com"]
        end

        dispatcher.dispatch(:recip_l1, email_to: ["inline@test.com"])

        expect(calls.first[:to]).to eq(["instance@test.com"])
      end
    end

    it "L2: payload class DSL wins over inline kwargs" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "recip_l2.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        payload_class = Class.new(Notify::PayloadClass) do
          email_recipients ["dsl@test.com"]
          subject "s"
        end
        stub_const("NotifyTemplates::RecipL2", payload_class)

        dispatcher.dispatch(:recip_l2, email_to: ["inline@test.com"])

        expect(calls.first[:to]).to eq(["dsl@test.com"])
      end
    end

    it "L3: inline kwarg wins over config" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "recip_l3.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:recip_l3] = { email_recipients: ["config@test.com"], subject: "s" }
          c.adapters[:email][:default_recipients] = ["global@test.com"]
        end

        dispatcher.dispatch(:recip_l3, email_to: ["inline@test.com"])

        expect(calls.first[:to]).to eq(["inline@test.com"])
      end
    end

    it "L4: per-message config wins over global defaults" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "recip_l4.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:recip_l4] = { email_recipients: ["config@test.com"], subject: "s" }
          c.adapters[:email][:default_recipients] = ["global@test.com"]
        end

        dispatcher.dispatch(:recip_l4)

        expect(calls.first[:to]).to eq(["config@test.com"])
      end
    end

    it "L5: global adapter default_recipients as last resort" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "recip_l5.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:recip_l5] = { subject: "s" }
          c.adapters[:email][:default_recipients] = ["global@test.com"]
        end

        dispatcher.dispatch(:recip_l5)

        expect(calls.first[:to]).to eq(["global@test.com"])
      end
    end

    it "raises MissingRecipients when no level resolves" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "no_recip.html.erb")
        Notify.build_registry!(dir)

        adapter_class, _calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:no_recip] = { subject: "s" }
          c.adapters[:email][:default_recipients] = []
        end

        expect { dispatcher.dispatch(:no_recip) }
          .to raise_error(Notify::DeliveryError)
      end
    end

    it "wraps a single recipient in an Array" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "single_recip.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:single_recip] = { subject: "s" }
          c.adapters[:email][:default_recipients] = "single@test.com"
        end

        dispatcher.dispatch(:single_recip)

        expect(calls.first[:to]).to eq(["single@test.com"])
      end
    end
  end

  describe "subject resolution" do
    it "resolves subject through priority chain (payload class > inline > config)" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "subj_chain.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        payload_class = Class.new(Notify::PayloadClass) do
          email_recipients ["r@t.com"]
          subject "from_class"
        end
        stub_const("NotifyTemplates::SubjChain", payload_class)

        Notify.configure do |c|
          c.messages[:subj_chain] = { subject: "from_config" }
        end

        dispatcher.dispatch(:subj_chain, subject: "from_inline")

        expect(calls.first[:subject]).to eq("from_class")
      end
    end

    it "raises MissingSubject for email adapter when subject is nil" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "no_subj.html.erb")
        Notify.build_registry!(dir)

        adapter_class, _calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.adapters[:email][:default_recipients] = ["r@t.com"]
        end

        expect { dispatcher.dispatch(:no_subj) }
          .to raise_error(Notify::DeliveryError)
      end
    end

    it "raises MissingSubject for email when subject is whitespace-only" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "blank_subj.html.erb")
        Notify.build_registry!(dir)

        adapter_class, _calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.adapters[:email][:default_recipients] = ["r@t.com"]
          c.messages[:blank_subj] = { subject: "   " }
        end

        expect { dispatcher.dispatch(:blank_subj) }
          .to raise_error(Notify::DeliveryError)
      end
    end

    it "does NOT raise MissingSubject for telegram adapter" do
      Dir.mktmpdir do |dir|
        create_template(dir, "telegram", "no_subj_tg.md.erb")
        Notify.build_registry!(dir)

        tg_class, calls = build_test_adapter
        Notify.register_adapter(:telegram, tg_class)

        Notify.configure do |c|
          c.adapters[:telegram][:enabled] = true
          c.messages[:no_subj_tg] = { tg_recipients: ["bot1"] }
        end

        dispatcher.dispatch(:no_subj_tg)

        expect(calls.size).to eq(1)
        expect(calls.first[:subject]).to be_nil
      end
    end

    it "does NOT raise MissingSubject for custom adapters" do
      Dir.mktmpdir do |dir|
        create_template(dir, "slack", "no_subj_custom.md.erb")
        Notify.build_registry!(dir)

        slack_class, calls = build_test_adapter
        Notify.register_adapter(:slack, slack_class)

        dispatcher.dispatch(:no_subj_custom, to: ["channel"])

        expect(calls.size).to eq(1)
        expect(calls.first[:subject]).to be_nil
      end
    end
  end

  describe "locals resolution" do
    it "uses PayloadClass#resolve_locals when payload class exists" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "locals_pc.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        payload_class = Class.new(Notify::PayloadClass) do
          email_recipients ["r@t.com"]
          subject "s"
          locals { { computed: true } }
        end
        stub_const("NotifyTemplates::LocalsPc", payload_class)

        dispatcher.dispatch(:locals_pc, raw_data: "ignored_by_class")

        expect(calls.first[:locals]).to eq({ computed: true })
      end
    end

    it "uses raw payload minus RESERVED_KEYS when no payload class" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "locals_raw.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:locals_raw] = { email_recipients: ["r@t.com"], subject: "s" }
        end

        dispatcher.dispatch(:locals_raw, custom_data: "hello", subject: "override", email_to: ["x@y.com"])

        expect(calls.first[:locals]).to eq({ custom_data: "hello" })
      end
    end
  end

  describe "options resolution" do
    it "resolves email_from through priority chain" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "opts_from.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:opts_from] = { email_recipients: ["r@t.com"], subject: "s", email_from: "msg@t.com" }
          c.adapters[:email][:from] = "global@t.com"
        end

        dispatcher.dispatch(:opts_from)

        expect(calls.first[:options][:from]).to eq("msg@t.com")
      end
    end

    it "falls back to adapter config :from when no other source" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "opts_from_global.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:opts_from_global] = { email_recipients: ["r@t.com"], subject: "s" }
          c.adapters[:email][:from] = "global@t.com"
        end

        dispatcher.dispatch(:opts_from_global)

        expect(calls.first[:options][:from]).to eq("global@t.com")
      end
    end

    it "includes cc only when non-nil" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "opts_cc.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:opts_cc] = { email_recipients: ["r@t.com"], subject: "s", email_cc: ["cc@t.com"] }
        end

        dispatcher.dispatch(:opts_cc)

        expect(calls.first[:options][:cc]).to eq(["cc@t.com"])
      end
    end

    it "does not include cc key when cc is nil" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "opts_no_cc.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:opts_no_cc] = { email_recipients: ["r@t.com"], subject: "s" }
        end

        dispatcher.dispatch(:opts_no_cc)

        expect(calls.first[:options]).not_to have_key(:cc)
        expect(calls.first[:options]).not_to have_key(:bcc)
      end
    end

    it "resolves delivery_method from message config" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "opts_dm.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:opts_dm] = { email_recipients: ["r@t.com"], subject: "s", delivery_method: :deliver_now }
        end

        dispatcher.dispatch(:opts_dm)

        expect(calls.first[:options][:delivery_method]).to eq(:deliver_now)
      end
    end

    it "non-email adapters get minimal options (delivery_method only)" do
      Dir.mktmpdir do |dir|
        create_template(dir, "telegram", "opts_tg.md.erb")
        Notify.build_registry!(dir)

        tg_class, calls = build_test_adapter
        Notify.register_adapter(:telegram, tg_class)

        Notify.configure do |c|
          c.adapters[:telegram][:enabled] = true
          c.messages[:opts_tg] = { tg_recipients: ["bot1"] }
        end

        dispatcher.dispatch(:opts_tg)

        expect(calls.first[:options]).not_to have_key(:from)
        expect(calls.first[:options]).not_to have_key(:cc)
        expect(calls.first[:options]).not_to have_key(:bcc)
      end
    end
  end

  describe "error isolation" do
    it "one adapter fails, another succeeds — no raise, error logged" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "partial_fail.html.erb")
        create_template(dir, "telegram", "partial_fail.md.erb")
        Notify.build_registry!(dir)

        email_class, email_calls = build_test_adapter
        tg_class = build_failing_adapter
        Notify.register_adapter(:email, email_class)
        Notify.register_adapter(:telegram, tg_class)

        Notify.configure do |c|
          c.adapters[:telegram][:enabled] = true
          c.messages[:partial_fail] = { email_recipients: ["r@t.com"], subject: "s", tg_recipients: ["bot1"] }
        end

        expect(logger).to receive(:error).with(/Adapter :telegram failed/)

        expect { dispatcher.dispatch(:partial_fail) }.not_to raise_error

        expect(email_calls.size).to eq(1)
      end
    end

    it "all adapters fail — raises DeliveryError with adapter_errors" do
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

        expect { dispatcher.dispatch(:all_fail) }
          .to raise_error(Notify::DeliveryError) { |e|
            expect(e.adapter_errors.keys).to contain_exactly(:email, :telegram)
            expect(e.adapter_errors[:email].message).to eq("email boom")
            expect(e.adapter_errors[:telegram].message).to eq("tg boom")
          }
      end
    end

    it "MissingRecipients is caught as adapter error (not propagated alone)" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "missing_r.html.erb")
        create_template(dir, "telegram", "missing_r.md.erb")
        Notify.build_registry!(dir)

        email_class, _calls = build_test_adapter
        tg_class, tg_calls = build_test_adapter
        Notify.register_adapter(:email, email_class)
        Notify.register_adapter(:telegram, tg_class)

        Notify.configure do |c|
          c.adapters[:email][:default_recipients] = []
          c.adapters[:telegram][:enabled] = true
          c.messages[:missing_r] = { subject: "s", tg_recipients: ["bot1"] }
        end

        expect { dispatcher.dispatch(:missing_r) }.not_to raise_error

        expect(tg_calls.size).to eq(1)
      end
    end

    it "MissingSubject is caught as adapter error" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "missing_s.html.erb")
        create_template(dir, "telegram", "missing_s.md.erb")
        Notify.build_registry!(dir)

        email_class, _calls = build_test_adapter
        tg_class, tg_calls = build_test_adapter
        Notify.register_adapter(:email, email_class)
        Notify.register_adapter(:telegram, tg_class)

        Notify.configure do |c|
          c.adapters[:email][:default_recipients] = ["r@t.com"]
          c.adapters[:telegram][:enabled] = true
          c.messages[:missing_s] = { tg_recipients: ["bot1"] }
        end

        expect { dispatcher.dispatch(:missing_s) }.not_to raise_error

        expect(tg_calls.size).to eq(1)
      end
    end
  end

  describe "instrumentation" do
    it "emits notify.message.dispatch with message_name and adapters" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "instr.html.erb")
        Notify.build_registry!(dir)

        adapter_class, _calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:instr] = { email_recipients: ["r@t.com"], subject: "s" }
        end

        events = []
        sub = ActiveSupport::Notifications.subscribe("notify.message.dispatch") do |event|
          events << event
        end

        dispatcher.dispatch(:instr)

        ActiveSupport::Notifications.unsubscribe(sub)

        expect(events.size).to eq(1)
        expect(events.first.payload[:message_name]).to eq(:instr)
        expect(events.first.payload[:adapters]).to eq([:email])
      end
    end

    it "emits notify.adapter.deliver per adapter" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "instr_d.html.erb")
        Notify.build_registry!(dir)

        adapter_class, _calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:instr_d] = { email_recipients: ["r@t.com"], subject: "s" }
        end

        events = []
        sub = ActiveSupport::Notifications.subscribe("notify.adapter.deliver") do |event|
          events << event
        end

        dispatcher.dispatch(:instr_d)

        ActiveSupport::Notifications.unsubscribe(sub)

        expect(events.size).to eq(1)
        expect(events.first.payload[:message_name]).to eq(:instr_d)
        expect(events.first.payload[:adapter]).to eq(:email)
        expect(events.first.payload[:to]).to eq(["r@t.com"])
      end
    end

    it "emits notify.adapter.error on failure" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "instr_e.html.erb")
        Notify.build_registry!(dir)

        failing_class = build_failing_adapter
        Notify.register_adapter(:email, failing_class)

        Notify.configure do |c|
          c.messages[:instr_e] = { email_recipients: ["r@t.com"], subject: "s" }
        end

        events = []
        sub = ActiveSupport::Notifications.subscribe("notify.adapter.error") do |event|
          events << event
        end

        expect { dispatcher.dispatch(:instr_e) }.to raise_error(Notify::DeliveryError)

        ActiveSupport::Notifications.unsubscribe(sub)

        expect(events.size).to eq(1)
        expect(events.first.payload[:message_name]).to eq(:instr_e)
        expect(events.first.payload[:adapter]).to eq(:email)
        expect(events.first.payload[:error]).to be_a(RuntimeError)
      end
    end
  end

  describe "logging" do
    it "logs warn for unregistered adapter class" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "log_unreg.html.erb")
        create_template(dir, "ghost", "log_unreg.md.erb")
        Notify.build_registry!(dir)

        adapter_class, _calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:log_unreg] = { email_recipients: ["r@t.com"], subject: "s" }
        end

        expect(logger).to receive(:warn).with(/Adapter :ghost.*no registered class/)
        dispatcher.dispatch(:log_unreg)
      end
    end

    it "logs error for adapter delivery failure" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "log_err.html.erb")
        Notify.build_registry!(dir)

        failing_class = build_failing_adapter(RuntimeError, "kaboom")
        Notify.register_adapter(:email, failing_class)

        Notify.configure do |c|
          c.messages[:log_err] = { email_recipients: ["r@t.com"], subject: "s" }
        end

        expect(logger).to receive(:error).with(/Adapter :email failed.*kaboom/)

        expect { dispatcher.dispatch(:log_err) }.to raise_error(Notify::DeliveryError)
      end
    end
  end

  describe "template_path computation" do
    it "passes the correct template path to the adapter" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "tpath.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:tpath] = { email_recipients: ["r@t.com"], subject: "s" }
        end

        dispatcher.dispatch(:tpath)

        expect(calls.first[:template_path]).to eq(Pathname(dir).join("email"))
      end
    end
  end

  describe "custom adapter convention fallback" do
    it "uses :foo_recipients method for custom adapter :foo" do
      Dir.mktmpdir do |dir|
        create_template(dir, "slack", "custom_conv.md.erb")
        Notify.build_registry!(dir)

        slack_class, calls = build_test_adapter
        Notify.register_adapter(:slack, slack_class)

        payload_class = Class.new(Notify::PayloadClass) do
          def slack_recipients
            ["#general"]
          end
        end
        stub_const("NotifyTemplates::CustomConv", payload_class)

        dispatcher.dispatch(:custom_conv)

        expect(calls.first[:to]).to eq(["#general"])
      end
    end
  end
end
