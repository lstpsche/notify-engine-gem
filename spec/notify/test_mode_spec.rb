# frozen_string_literal: true

require "notify"
require "fileutils"
require "tmpdir"

RSpec.describe "test mode" do
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
  end

  describe "Notify.test_mode!" do
    it "activates test mode" do
      Notify.test_mode!

      expect(Notify.test_mode?).to be true
    end

    it "is idempotent" do
      Notify.test_mode!
      Notify.test_mode!

      expect(Notify.test_mode?).to be true
    end
  end

  describe "Notify.test_mode?" do
    it "returns false by default" do
      expect(Notify.test_mode?).to be false
    end
  end

  describe "Notify.deliveries" do
    it "returns an Array" do
      expect(Notify.deliveries).to be_an(Array)
    end

    it "returns the same instance on repeated calls" do
      first = Notify.deliveries
      second = Notify.deliveries

      expect(first).to equal(second)
    end

    it "supports .clear" do
      Notify.deliveries << { name: :test }
      Notify.deliveries.clear

      expect(Notify.deliveries).to be_empty
    end
  end

  describe "Notify.reset_test_mode!" do
    it "deactivates test mode and clears deliveries" do
      Notify.test_mode!
      Notify.deliveries << { name: :test }

      Notify.reset_test_mode!

      expect(Notify.test_mode?).to be false
      expect(Notify.deliveries).to be_empty
    end
  end

  describe "Notify.message in test mode" do
    it "captures delivery hash in Notify.deliveries" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "captured.html.erb")
        Notify.build_registry!(dir)

        adapter_class, _calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:captured] = { email_recipients: ["user@test.com"], subject: "Test" }
        end

        Notify.test_mode!
        Notify.message(:captured, data: "value")

        expect(Notify.deliveries.size).to eq(1)
      end
    end

    it "does NOT call real adapter deliver" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "no_deliver.html.erb")
        Notify.build_registry!(dir)

        adapter_class, calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:no_deliver] = { email_recipients: ["u@t.com"], subject: "S" }
        end

        Notify.test_mode!
        Notify.message(:no_deliver, data: "v")

        expect(calls).to be_empty
      end
    end

    it "produces delivery hash with correct structure" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "structure.html.erb")
        Notify.build_registry!(dir)

        adapter_class, _calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:structure] = { email_recipients: ["user@test.com"], subject: "Subject" }
        end

        Notify.test_mode!
        Notify.message(:structure, report: "data")

        delivery = Notify.deliveries.first
        expect(delivery[:name]).to eq(:structure)
        expect(delivery[:adapters]).to eq([:email])
        expect(delivery[:payload]).to eq({ report: "data" })
        expect(delivery[:resolved]).to be_a(Hash)
        expect(delivery[:resolved][:subject]).to eq("Subject")
        expect(delivery[:resolved][:recipients]).to eq({ email: ["user@test.com"] })
        expect(delivery[:resolved][:locals]).to eq({ report: "data" })
      end
    end

    it "raises UnknownMessage for unregistered messages" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "exists.html.erb")
        Notify.build_registry!(dir)

        Notify.test_mode!

        expect { Notify.message(:nonexistent) }
          .to raise_error(Notify::UnknownMessage, /nonexistent/)
      end
    end

    it "captures per-adapter resolution errors without propagating" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "err_capture.html.erb")
        create_template(dir, "telegram", "err_capture.md.erb")
        Notify.build_registry!(dir)

        email_class, _email_calls = build_test_adapter
        tg_class, _tg_calls = build_test_adapter
        Notify.register_adapter(:email, email_class)
        Notify.register_adapter(:telegram, tg_class)

        Notify.configure do |c|
          c.adapters[:telegram][:enabled] = true
          c.messages[:err_capture] = { tg_recipients: ["bot1"] }
        end

        Notify.test_mode!

        expect { Notify.message(:err_capture) }.not_to raise_error

        delivery = Notify.deliveries.first
        expect(delivery[:errors]).to have_key(:email)
        expect(delivery[:errors][:email]).to be_a(Notify::MissingRecipients)
        expect(delivery[:resolved][:recipients]).to have_key(:telegram)
        expect(delivery[:resolved][:recipients]).not_to have_key(:email)
      end
    end

    it "captures MissingSubject without leaking recipients into resolved hash" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "subj_err.html.erb")
        create_template(dir, "telegram", "subj_err.md.erb")
        Notify.build_registry!(dir)

        email_class, _email_calls = build_test_adapter
        tg_class, _tg_calls = build_test_adapter
        Notify.register_adapter(:email, email_class)
        Notify.register_adapter(:telegram, tg_class)

        Notify.configure do |c|
          c.adapters[:telegram][:enabled] = true
          c.messages[:subj_err] = { email_recipients: ["user@test.com"], tg_recipients: ["bot1"] }
        end

        Notify.test_mode!

        expect { Notify.message(:subj_err) }.not_to raise_error

        delivery = Notify.deliveries.first
        expect(delivery[:errors]).to have_key(:email)
        expect(delivery[:errors][:email]).to be_a(Notify::MissingSubject)
        expect(delivery[:resolved][:recipients]).not_to have_key(:email)
        expect(delivery[:resolved][:recipients]).to have_key(:telegram)
        expect(delivery[:resolved][:recipients][:telegram]).to eq(["bot1"])
      end
    end

    it "accumulates multiple dispatches in deliveries array" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "msg_one.html.erb")
        create_template(dir, "email", "msg_two.html.erb")
        create_template(dir, "email", "msg_three.html.erb")
        Notify.build_registry!(dir)

        adapter_class, _calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:msg_one] = { email_recipients: ["u@t.com"], subject: "S1" }
          c.messages[:msg_two] = { email_recipients: ["u@t.com"], subject: "S2" }
          c.messages[:msg_three] = { email_recipients: ["u@t.com"], subject: "S3" }
        end

        Notify.test_mode!
        Notify.message(:msg_one)
        Notify.message(:msg_two)
        Notify.message(:msg_three)

        expect(Notify.deliveries.size).to eq(3)
        expect(Notify.deliveries.map { |d| d[:name] }).to eq(%i[msg_one msg_two msg_three])
      end
    end

    it "handles raw payload mode (no payload class)" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "raw_test.html.erb")
        Notify.build_registry!(dir)

        adapter_class, _calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:raw_test] = { email_recipients: ["u@t.com"], subject: "S" }
        end

        Notify.test_mode!
        Notify.message(:raw_test, custom: "val", report_id: 42, subject: "override")

        delivery = Notify.deliveries.first
        expect(delivery[:resolved][:locals]).to eq({ custom: "val", report_id: 42 })
        expect(delivery[:resolved][:subject]).to eq("override")
      end
    end

    it "handles payload class initialization error gracefully" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "init_fail.html.erb")
        Notify.build_registry!(dir)

        adapter_class, _calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        payload_class = Class.new(Notify::PayloadClass) do
          def initialize(**_payload)
            raise "init kaboom"
          end
        end
        stub_const("NotifyTemplates::InitFail", payload_class)

        Notify.configure do |c|
          c.messages[:init_fail] = { email_recipients: ["u@t.com"], subject: "S" }
        end

        Notify.test_mode!

        expect(logger).to receive(:warn).with(/PayloadClass.*failed to initialize/)
        Notify.message(:init_fail, data: "raw")

        delivery = Notify.deliveries.first
        expect(delivery[:resolved][:locals]).to eq({ data: "raw" })
      end
    end

    it "resolves payload class data in test mode" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "pc_resolve.html.erb")
        Notify.build_registry!(dir)

        adapter_class, _calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        payload_class = Class.new(Notify::PayloadClass) do
          email_recipients ["dsl@test.com"]
          subject "DSL subject"
          locals { { computed: true } }

          def initialize(**payload)
            @data = payload[:data]
          end
        end
        stub_const("NotifyTemplates::PcResolve", payload_class)

        Notify.test_mode!
        Notify.message(:pc_resolve, data: "val")

        delivery = Notify.deliveries.first
        expect(delivery[:resolved][:recipients]).to eq({ email: ["dsl@test.com"] })
        expect(delivery[:resolved][:subject]).to eq("DSL subject")
        expect(delivery[:resolved][:locals]).to eq({ computed: true })
      end
    end

    it "captures multi-adapter delivery with recipients keyed by adapter" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "multi_cap.html.erb")
        create_template(dir, "telegram", "multi_cap.md.erb")
        Notify.build_registry!(dir)

        email_class, _email_calls = build_test_adapter
        tg_class, _tg_calls = build_test_adapter
        Notify.register_adapter(:email, email_class)
        Notify.register_adapter(:telegram, tg_class)

        Notify.configure do |c|
          c.adapters[:telegram][:enabled] = true
          c.messages[:multi_cap] = {
            email_recipients: ["e@t.com"],
            subject: "S",
            tg_recipients: ["bot1"]
          }
        end

        Notify.test_mode!
        Notify.message(:multi_cap)

        delivery = Notify.deliveries.first
        expect(delivery[:adapters]).to contain_exactly(:email, :telegram)
        expect(delivery[:resolved][:recipients]).to have_key(:email)
        expect(delivery[:resolved][:recipients]).to have_key(:telegram)
        expect(delivery[:resolved][:recipients][:email]).to eq(["e@t.com"])
        expect(delivery[:resolved][:recipients][:telegram]).to eq(["bot1"])
      end
    end
  end

  describe "Proc evaluation in config during capture" do
    it "evaluates Procs for recipients and subject in per-message config" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "proc_cap.html.erb")
        Notify.build_registry!(dir)

        adapter_class, _calls = build_test_adapter
        Notify.register_adapter(:email, adapter_class)

        Notify.configure do |c|
          c.messages[:proc_cap] = {
            email_recipients: -> { ["captured@test.com"] },
            subject: -> { "Captured Subject" }
          }
        end

        Notify.test_mode!
        Notify.message(:proc_cap, data: "val")

        delivery = Notify.deliveries.first
        expect(delivery[:resolved][:recipients][:email]).to eq(["captured@test.com"])
        expect(delivery[:resolved][:subject]).to eq("Captured Subject")
      end
    end
  end

  describe "engine initializer" do
    it "defines a notify_engine.test_mode initializer" do
      initializer = Notify::Engine.initializers.find { |i| i.name == "notify_engine.test_mode" }

      expect(initializer).not_to be_nil
    end

    it "test_mode initializer is defined after registry initializer" do
      names = Notify::Engine.initializers.map(&:name)
      registry_idx = names.index("notify_engine.registry")
      test_mode_idx = names.index("notify_engine.test_mode")

      expect(test_mode_idx).to be > registry_idx
    end
  end
end
