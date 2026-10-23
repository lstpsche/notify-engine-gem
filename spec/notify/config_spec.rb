# frozen_string_literal: true

require "notify"

RSpec.describe Notify::Config do
  describe "defaults" do
    it "sets the templates path" do
      expect(Notify.config.templates_path).to eq("app/notify_templates")
    end

    it "sets email adapter defaults" do
      expect(Notify.config.adapters[:email]).to eq(
        enabled: true,
        from: nil,
        delivery_method: :deliver_later,
        default_recipients: [],
        layout: false,
        helpers: [],
        subject_prefix: nil
      )
    end

    it "sets telegram adapter defaults" do
      expect(Notify.config.adapters[:telegram]).to eq(
        enabled: false,
        bots: [],
        open_timeout: 5,
        read_timeout: 15,
        write_timeout: 15
      )
    end

    it "starts with no per-message config" do
      expect(Notify.config.messages).to eq({})
    end
  end

  describe ".configure" do
    it "yields the config object for mutation" do
      Notify.configure do |config|
        config.templates_path = "custom/notify_templates"
        config.messages[:stuck_pg_jobs] = { subject: "Stuck PgJobs detected" }
      end

      expect(Notify.config.templates_path).to eq("custom/notify_templates")
      expect(Notify.config.messages[:stuck_pg_jobs]).to eq(subject: "Stuck PgJobs detected")
    end
  end

  describe ".reset_config!" do
    it "restores defaults" do
      Notify.configure do |config|
        config.templates_path = "custom"
        config.adapters[:email][:helpers] << :helper
        config.adapters[:telegram][:bots] << { name: "default" }
        config.messages[:message] = { subject: "Subject" }
      end

      Notify.reset_config!

      expect(Notify.config.templates_path).to eq("app/notify_templates")
      expect(Notify.config.adapters[:email][:helpers]).to eq([])
      expect(Notify.config.adapters[:telegram][:bots]).to eq([])
      expect(Notify.config.messages).to eq({})
    end

    it "does not share nested mutable defaults across resets" do
      Notify.config.adapters[:email][:helpers] << :helper
      Notify.config.adapters[:telegram][:bots] << { name: "alerts" }

      Notify.reset_config!

      expect(Notify.config.adapters[:email][:helpers]).to eq([])
      expect(Notify.config.adapters[:telegram][:bots]).to eq([])
    end
  end
end
