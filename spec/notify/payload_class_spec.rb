# frozen_string_literal: true

require "notify"

RSpec.describe Notify::PayloadClass do
  describe "DSL storage and retrieval" do
    it "stores and retrieves a static string value" do
      klass = Class.new(described_class) { subject "static subject" }
      expect(klass.subject).to eq("static subject")
    end

    it "stores a block as a Proc" do
      klass = Class.new(described_class) { subject { "from block" } }
      expect(klass.dsl_definitions[:subject]).to be_a(Proc)
    end

    it "stores a lambda" do
      klass = Class.new(described_class) { email_recipients -> { ["a@b.com"] } }
      stored = klass.dsl_definitions[:email_recipients]
      expect(stored).to be_a(Proc)
      expect(stored).to be_lambda
    end

    it "stores a static array" do
      klass = Class.new(described_class) { tg_recipients %i[bot1 bot2] }
      expect(klass.tg_recipients).to eq(%i[bot1 bot2])
    end

    it "returns nil when nothing is set" do
      klass = Class.new(described_class)
      expect(klass.subject).to be_nil
    end

    it "isolates DSL definitions per class" do
      klass_a = Class.new(described_class) { subject "A" }
      klass_b = Class.new(described_class) { subject "B" }

      expect(klass_a.subject).to eq("A")
      expect(klass_b.subject).to eq("B")
    end

    it "does not leak DSL from subclass to base class" do
      Class.new(described_class) { subject "leaked?" }
      expect(described_class.dsl_definitions).to be_empty
    end
  end

  describe "resolution priority" do
    it "prefers instance method over DSL" do
      klass = Class.new(described_class) do
        subject { "dsl subject" }
        define_method(:subject) { "instance subject" }
      end

      expect(klass.new.resolve(:subject)).to eq("instance subject")
    end

    it "uses DSL static value when no instance method" do
      klass = Class.new(described_class) { subject "static subject" }
      expect(klass.new.resolve(:subject)).to eq("static subject")
    end

    it "uses DSL block when no instance method" do
      klass = Class.new(described_class) { subject { "block subject" } }
      expect(klass.new.resolve(:subject)).to eq("block subject")
    end

    it "returns nil when neither instance method nor DSL is defined" do
      klass = Class.new(described_class)
      expect(klass.new.resolve(:subject)).to be_nil
    end
  end

  describe "deferred evaluation (instance_exec)" do
    it "evaluates a block with access to instance variables" do
      klass = Class.new(described_class) do
        subject { "count: #{@items.size}" }
        define_method(:initialize) { |**payload| @items = payload[:items] }
      end

      instance = klass.new(items: [1, 2, 3])
      expect(instance.resolve(:subject)).to eq("count: 3")
    end

    it "evaluates a lambda with access to instance variables" do
      klass = Class.new(described_class) do
        email_recipients -> { @admins }
        define_method(:initialize) { |**payload| @admins = payload[:admins] }
      end

      instance = klass.new(admins: ["a@b.com"])
      expect(instance.resolve(:email_recipients)).to eq(["a@b.com"])
    end

    it "returns static values as-is without evaluating" do
      klass = Class.new(described_class) { tg_recipients %i[bot1 bot2] }
      expect(klass.new.resolve(:tg_recipients)).to eq(%i[bot1 bot2])
    end
  end

  describe "locals resolution" do
    it "returns value from an explicit locals instance method" do
      klass = Class.new(described_class) do
        define_method(:initialize) { |**payload| @data = payload[:data] }
        define_method(:locals) { { data: @data, extra: true } }
      end

      instance = klass.new(data: "value")
      expect(instance.resolve_locals).to eq(data: "value", extra: true)
    end

    it "returns value from a locals DSL block" do
      klass = Class.new(described_class) { locals { { computed: true } } }
      expect(klass.new.resolve_locals).to eq(computed: true)
    end

    it "falls back to raw payload minus reserved keys when no locals defined" do
      klass = Class.new(described_class)
      instance = klass.new(pg_jobs: [1, 2], custom: "val", subject: "strip me", email_to: "strip@me.com")
      expect(instance.resolve_locals).to eq(pg_jobs: [1, 2], custom: "val")
    end

    it "falls back to default locals when locals method returns nil" do
      klass = Class.new(described_class) do
        define_method(:locals) { nil }
      end

      instance = klass.new(data: "val")
      expect(instance.resolve_locals).to eq(data: "val")
    end
  end

  describe "reserved keys" do
    it "contains exactly the expected symbols" do
      expect(described_class::RESERVED_KEYS).to eq(
        %i[subject email_to email_from email_cc email_bcc tg_bots delivery_method]
      )
    end

    it "is frozen" do
      expect(described_class::RESERVED_KEYS).to be_frozen
    end

    it "strips all reserved keys from default_locals" do
      klass = Class.new(described_class)
      payload = {
        subject: "s", email_to: "e", email_from: "f",
        email_cc: "c", email_bcc: "b", tg_bots: "t",
        delivery_method: :deliver_now, custom: "keep"
      }
      instance = klass.new(**payload)
      expect(instance.default_locals).to eq(custom: "keep")
    end

    it "preserves all non-reserved keys in default_locals" do
      klass = Class.new(described_class)
      instance = klass.new(pg_jobs: [1], report_data: "x", flag: true)
      expect(instance.default_locals).to eq(pg_jobs: [1], report_data: "x", flag: true)
    end
  end

  describe "raw payload capture" do
    it "sets @_raw_payload without subclass calling super" do
      klass = Class.new(described_class) do
        define_method(:initialize) { |**payload| @items = payload[:items] }
      end

      instance = klass.new(items: [1, 2])
      expect(instance.instance_variable_get(:@_raw_payload)).to eq(items: [1, 2])
    end

    it "freezes @_raw_payload" do
      instance = described_class.new(foo: "bar")
      expect(instance.instance_variable_get(:@_raw_payload)).to be_frozen
    end

    it "passes an unfrozen copy to subclass initialize" do
      received_frozen = nil
      klass = Class.new(described_class) do
        define_method(:initialize) do |**payload|
          received_frozen = payload.frozen?
          payload[:mutated] = true
        end
      end

      klass.new(foo: "bar")
      expect(received_frozen).to be false
    end
  end

  describe "all DSL methods" do
    describe "email_recipients" do
      it "resolves a static value" do
        klass = Class.new(described_class) { email_recipients ["a@b.com"] }
        expect(klass.new.resolve(:email_recipients)).to eq(["a@b.com"])
      end

      it "resolves a block with instance context" do
        klass = Class.new(described_class) do
          email_recipients { @emails }
          define_method(:initialize) { |**payload| @emails = payload[:emails] }
        end

        expect(klass.new(emails: ["x@y.com"]).resolve(:email_recipients)).to eq(["x@y.com"])
      end

      it "resolves a lambda with instance context" do
        klass = Class.new(described_class) do
          email_recipients -> { @emails }
          define_method(:initialize) { |**payload| @emails = payload[:emails] }
        end

        expect(klass.new(emails: ["x@y.com"]).resolve(:email_recipients)).to eq(["x@y.com"])
      end

      it "prefers instance method over DSL" do
        klass = Class.new(described_class) do
          email_recipients ["dsl@b.com"]
          define_method(:email_recipients) { ["instance@b.com"] }
        end

        expect(klass.new.resolve(:email_recipients)).to eq(["instance@b.com"])
      end
    end

    it "resolves email_from" do
      klass = Class.new(described_class) { email_from "alerts@novus.online" }
      expect(klass.new.resolve(:email_from)).to eq("alerts@novus.online")
    end

    it "resolves email_cc" do
      klass = Class.new(described_class) { email_cc ["manager@novus.ua"] }
      expect(klass.new.resolve(:email_cc)).to eq(["manager@novus.ua"])
    end

    it "resolves email_bcc" do
      klass = Class.new(described_class) { email_bcc { ["hidden@novus.ua"] } }
      expect(klass.new.resolve(:email_bcc)).to eq(["hidden@novus.ua"])
    end

    it "resolves tg_recipients" do
      klass = Class.new(described_class) { tg_recipients -> { %i[alerts_bot notifier] } }
      expect(klass.new.resolve(:tg_recipients)).to eq(%i[alerts_bot notifier])
    end
  end

  describe "edge cases" do
    it "stores and resolves false as a DSL value" do
      klass = Class.new(described_class) { email_cc false }
      expect(klass.dsl_definitions[:email_cc]).to be false
      expect(klass.new.resolve(:email_cc)).to be false
    end

    it "returns empty hash for default locals with empty payload" do
      klass = Class.new(described_class)
      expect(klass.new.resolve_locals).to eq({})
    end

    it "returns empty hash for default locals when payload has only reserved keys" do
      klass = Class.new(described_class)
      instance = klass.new(subject: "s", email_to: "e", delivery_method: :deliver_now)
      expect(instance.resolve_locals).to eq({})
    end
  end

  describe "integration (StuckPgJobs-style)" do
    let(:klass) do
      Class.new(described_class) do
        subject { "DSL subject (should be overridden)" }
        email_recipients -> { @admin_emails }
        email_from "dsl-from@novus.online"
        email_cc ["manager@novus.ua"]
        email_bcc { ["audit@novus.ua"] }
        tg_recipients %i[alerts_bot notifier]
        locals { { pg_jobs: @pg_jobs, detected_at: @detected_at } }

        define_method(:initialize) do |**payload|
          @pg_jobs = payload[:pg_jobs]
          @admin_emails = payload[:admin_emails]
          @detected_at = payload[:detected_at]
        end

        define_method(:subject) { "\u26A0\uFE0F #{@pg_jobs.size} stuck PgJob(s) detected" }
        define_method(:email_from) { "alerts@novus.online" }
      end
    end

    let(:instance) do
      klass.new(
        pg_jobs: %w[job1 job2 job3],
        admin_emails: ["admin@novus.online"],
        detected_at: "2026-05-28T21:00:00Z"
      )
    end

    it "resolves subject via instance method (overrides DSL)" do
      expect(instance.resolve(:subject)).to eq("\u26A0\uFE0F 3 stuck PgJob(s) detected")
    end

    it "resolves email_recipients via DSL lambda with instance vars" do
      expect(instance.resolve(:email_recipients)).to eq(["admin@novus.online"])
    end

    it "resolves email_from via instance method (overrides DSL)" do
      expect(instance.resolve(:email_from)).to eq("alerts@novus.online")
    end

    it "resolves email_cc as DSL static array" do
      expect(instance.resolve(:email_cc)).to eq(["manager@novus.ua"])
    end

    it "resolves email_bcc via DSL block" do
      expect(instance.resolve(:email_bcc)).to eq(["audit@novus.ua"])
    end

    it "resolves tg_recipients as DSL static symbol array" do
      expect(instance.resolve(:tg_recipients)).to eq(%i[alerts_bot notifier])
    end

    it "resolves locals via DSL block with instance vars" do
      expect(instance.resolve_locals).to eq(
        pg_jobs: %w[job1 job2 job3],
        detected_at: "2026-05-28T21:00:00Z"
      )
    end
  end
end
