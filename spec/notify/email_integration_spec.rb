# frozen_string_literal: true

require "notify"
require "action_mailer"
require "tmpdir"
require "fileutils"

ActionMailer::Base.delivery_method = :test
ActiveJob::Base.queue_adapter = :inline

RSpec.describe "email integration" do
  let(:logger) { Logger.new(IO::NULL) }

  def create_template(base, *path_parts, content: "")
    full_path = File.join(base, *path_parts)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, content)
  end

  before do
    ActionMailer::Base.deliveries.clear
    allow(Rails).to receive(:logger).and_return(logger)
    Notify.configure { |c| c.adapters[:email][:from] = "default@test.com" }
  end

  after do
    Notify::Mailer.layout(false)
    Notify::Mailer.instance_variable_set(:@view_context_class, nil)
  end

  def register_email_adapter
    Notify.register_adapter(:email, Notify::Adapters::Email)
  end

  describe "basic email rendering" do
    it "renders a template with instance variables from locals" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "greeting.html.erb", content: "<h1><%= @greeting %></h1>")
        Notify.build_registry!(dir)
        register_email_adapter

        Notify.configure do |c|
          c.messages[:greeting] = { email_recipients: ["user@test.com"], subject: "Hello" }
        end

        Notify.message(:greeting, greeting: "Welcome")

        mail = ActionMailer::Base.deliveries.last
        expect(mail.to).to eq(["user@test.com"])
        expect(mail.subject).to eq("Hello")
        expect(mail.body.to_s).to include("Welcome")
      end
    end

    it "renders multipart email when both html and text templates exist" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "multi.html.erb", content: "<b><%= @data %></b>")
        create_template(dir, "email", "multi.text.erb", content: "Plain: <%= @data %>")
        Notify.build_registry!(dir)
        register_email_adapter

        Notify.configure do |c|
          c.messages[:multi] = { email_recipients: ["user@test.com"], subject: "Multi" }
        end

        Notify.message(:multi, data: "content")

        mail = ActionMailer::Base.deliveries.last
        expect(mail.parts.size).to eq(2)
        expect(mail.html_part.body.to_s).to include("<b>content</b>")
        expect(mail.text_part.body.to_s).to include("Plain: content")
      end
    end
  end

  describe "subject prefix" do
    it "prepends a string prefix" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "prefixed.html.erb", content: "body")
        Notify.build_registry!(dir)
        register_email_adapter

        Notify.configure do |c|
          c.adapters[:email][:subject_prefix] = "[TEST]:"
          c.messages[:prefixed] = { email_recipients: ["r@test.com"], subject: "Alert" }
        end

        Notify.message(:prefixed)

        expect(ActionMailer::Base.deliveries.last.subject).to eq("[TEST]: Alert")
      end
    end

    it "evaluates and prepends a Proc prefix" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "proc_prefix.html.erb", content: "body")
        Notify.build_registry!(dir)
        register_email_adapter

        Notify.configure do |c|
          c.adapters[:email][:subject_prefix] = -> { "[DYNAMIC]:" }
          c.messages[:proc_prefix] = { email_recipients: ["r@test.com"], subject: "Alert" }
        end

        Notify.message(:proc_prefix)

        expect(ActionMailer::Base.deliveries.last.subject).to eq("[DYNAMIC]: Alert")
      end
    end

    it "leaves subject unchanged when prefix is nil" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "no_prefix.html.erb", content: "body")
        Notify.build_registry!(dir)
        register_email_adapter

        Notify.configure do |c|
          c.adapters[:email][:subject_prefix] = nil
          c.messages[:no_prefix] = { email_recipients: ["r@test.com"], subject: "Plain" }
        end

        Notify.message(:no_prefix)

        expect(ActionMailer::Base.deliveries.last.subject).to eq("Plain")
      end
    end
  end

  describe "delivery method" do
    it "delivers via deliver_later by default (mail lands in deliveries)" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "later_msg.html.erb", content: "body")
        Notify.build_registry!(dir)
        register_email_adapter

        Notify.configure do |c|
          c.messages[:later_msg] = { email_recipients: ["r@test.com"], subject: "Later" }
        end

        Notify.message(:later_msg)

        expect(ActionMailer::Base.deliveries.size).to eq(1)
      end
    end

    it "delivers via deliver_now when overridden" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "now_msg.html.erb", content: "body")
        Notify.build_registry!(dir)
        register_email_adapter

        Notify.configure do |c|
          c.messages[:now_msg] = { email_recipients: ["r@test.com"], subject: "Now" }
        end

        Notify.message(:now_msg, delivery_method: :deliver_now)

        expect(ActionMailer::Base.deliveries.size).to eq(1)
        expect(ActionMailer::Base.deliveries.last.subject).to eq("Now")
      end
    end
  end

  describe "from/cc/bcc" do
    it "sets from via payload class email_from" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "from_test.html.erb", content: "body")
        Notify.build_registry!(dir)
        register_email_adapter

        payload_class = Class.new(Notify::PayloadClass) do
          email_recipients ["user@test.com"]
          subject "Test"

          def email_from
            "sender@custom.com"
          end
        end
        stub_const("NotifyTemplates::FromTest", payload_class)

        Notify.message(:from_test)

        expect(ActionMailer::Base.deliveries.last.from).to eq(["sender@custom.com"])
      end
    end

    it "sets cc and bcc via payload class" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "cc_bcc_test.html.erb", content: "body")
        Notify.build_registry!(dir)
        register_email_adapter

        payload_class = Class.new(Notify::PayloadClass) do
          email_recipients ["user@test.com"]
          subject "Test"

          def email_from
            "sender@test.com"
          end

          def email_cc
            ["cc@test.com"]
          end

          def email_bcc
            ["bcc@test.com"]
          end
        end
        stub_const("NotifyTemplates::CcBccTest", payload_class)

        Notify.message(:cc_bcc_test)

        mail = ActionMailer::Base.deliveries.last
        expect(mail.cc).to eq(["cc@test.com"])
        expect(mail.bcc).to eq(["bcc@test.com"])
      end
    end

    it "omits cc/bcc when not set" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "no_cc.html.erb", content: "body")
        Notify.build_registry!(dir)
        register_email_adapter

        Notify.configure do |c|
          c.messages[:no_cc] = { email_recipients: ["r@test.com"], subject: "S" }
        end

        Notify.message(:no_cc)

        mail = ActionMailer::Base.deliveries.last
        expect(mail.cc).to be_nil
        expect(mail.bcc).to be_nil
      end
    end
  end

  describe "layout and helpers" do
    it "wraps template in a configured layout" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "with_layout.html.erb", content: "<p>inner content</p>")

        layout_dir = File.join(dir, "layouts_view")
        FileUtils.mkdir_p(File.join(layout_dir, "layouts"))
        File.write(
          File.join(layout_dir, "layouts", "custom_layout.html.erb"),
          "<html><body>LAYOUT_HEADER<%= yield %>LAYOUT_FOOTER</body></html>"
        )
        Notify::Mailer.prepend_view_path(layout_dir)

        Notify.build_registry!(dir)
        register_email_adapter

        Notify.configure do |c|
          c.adapters[:email][:layout] = "custom_layout"
          c.messages[:with_layout] = { email_recipients: ["r@test.com"], subject: "Layout" }
        end

        Notify.message(:with_layout)

        body = ActionMailer::Base.deliveries.last.body.to_s
        expect(body).to include("LAYOUT_HEADER")
        expect(body).to include("inner content")
        expect(body).to include("LAYOUT_FOOTER")
      end
    end

    it "makes helper methods accessible in templates" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "with_helper.html.erb", content: "<%= format_greeting('World') %>")
        Notify.build_registry!(dir)
        register_email_adapter

        helper_mod = Module.new do
          def format_greeting(name)
            "Hello, #{name}!"
          end
        end

        Notify.configure do |c|
          c.adapters[:email][:helpers] = [helper_mod]
          c.messages[:with_helper] = { email_recipients: ["r@test.com"], subject: "Helper" }
        end

        Notify.message(:with_helper)

        expect(ActionMailer::Base.deliveries.last.body.to_s).to include("Hello, World!")
      end
    end

    it "renders without layout by default" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "no_layout.html.erb", content: "<p>bare content</p>")
        Notify.build_registry!(dir)
        register_email_adapter

        Notify.configure do |c|
          c.messages[:no_layout] = { email_recipients: ["r@test.com"], subject: "NoLayout" }
        end

        Notify.message(:no_layout)

        body = ActionMailer::Base.deliveries.last.body.to_s
        expect(body).to include("<p>bare content</p>")
        expect(body).not_to include("LAYOUT")
      end
    end
  end

  describe "instance variable safety" do
    it "skips underscore-prefixed locals with warning" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "ivar_safety.html.erb", content: "safe:<%= @safe %>")
        Notify.build_registry!(dir)
        register_email_adapter

        Notify.configure do |c|
          c.messages[:ivar_safety] = { email_recipients: ["r@test.com"], subject: "Safety" }
        end

        expect(logger).to receive(:warn).with(/Skipping local '_internal'/)

        Notify.message(:ivar_safety, _internal: "secret", safe: "visible")

        expect(ActionMailer::Base.deliveries.last.body.to_s).to include("safe:visible")
      end
    end

    it "preserves nil values in template rendering" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "nil_val.html.erb",
          content: "<%= @present %>|<%= @missing.nil? ? 'was_nil' : 'not_nil' %>")
        Notify.build_registry!(dir)
        register_email_adapter

        Notify.configure do |c|
          c.messages[:nil_val] = { email_recipients: ["r@test.com"], subject: "Nil" }
        end

        Notify.message(:nil_val, present: "yes", missing: nil)

        body = ActionMailer::Base.deliveries.last.body.to_s
        expect(body).to include("yes")
        expect(body).to include("was_nil")
      end
    end
  end

  describe "payload class integration" do
    it "resolves recipients, subject, and locals through payload class to rendered email" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "full_payload.html.erb",
          content: "Jobs:<%= @pg_jobs.size %> at <%= @detected_at %>")
        Notify.build_registry!(dir)
        register_email_adapter

        payload_class = Class.new(Notify::PayloadClass) do
          email_recipients ["admin@test.com"]
          subject { "#{@pg_jobs.size} stuck jobs" }
          locals { { pg_jobs: @pg_jobs, detected_at: "2026-05-28" } }

          def initialize(**payload)
            @pg_jobs = payload[:pg_jobs]
          end

          def email_from
            "alerts@test.com"
          end
        end
        stub_const("NotifyTemplates::FullPayload", payload_class)

        Notify.message(:full_payload, pg_jobs: %w[job1 job2 job3])

        mail = ActionMailer::Base.deliveries.last
        expect(mail.to).to eq(["admin@test.com"])
        expect(mail.subject).to eq("3 stuck jobs")
        expect(mail.from).to eq(["alerts@test.com"])
        expect(mail.body.to_s).to include("Jobs:3")
        expect(mail.body.to_s).to include("2026-05-28")
      end
    end

    it "uses raw payload mode when no payload class exists" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "raw_email.html.erb",
          content: "Report:<%= @report_id %>")
        Notify.build_registry!(dir)
        register_email_adapter

        Notify.message(:raw_email, email_to: ["user@test.com"], subject: "Raw", report_id: 42)

        mail = ActionMailer::Base.deliveries.last
        expect(mail.to).to eq(["user@test.com"])
        expect(mail.subject).to eq("Raw")
        expect(mail.body.to_s).to include("Report:42")
      end
    end
  end

  describe "full resolution priority chain" do
    it "payload class instance method wins over all other levels" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "priority.html.erb",
          content: "Winner:<%= @source %>")
        Notify.build_registry!(dir)
        register_email_adapter

        payload_class = Class.new(Notify::PayloadClass) do
          email_recipients ["dsl@test.com"]
          subject "dsl subject"

          def initialize(**payload)
            @source = payload[:source]
          end

          def email_recipients
            ["instance@test.com"]
          end

          def subject
            "instance subject"
          end

          def email_from
            "instance@from.com"
          end
        end
        stub_const("NotifyTemplates::Priority", payload_class)

        Notify.configure do |c|
          c.messages[:priority] = { email_recipients: ["config@test.com"], subject: "config subject" }
          c.adapters[:email][:default_recipients] = ["global@test.com"]
        end

        Notify.message(:priority,
          email_to: ["inline@test.com"], subject: "inline subject", source: "payload")

        mail = ActionMailer::Base.deliveries.last
        expect(mail.to).to eq(["instance@test.com"])
        expect(mail.subject).to eq("instance subject")
        expect(mail.from).to eq(["instance@from.com"])
        expect(mail.body.to_s).to include("Winner:payload")
      end
    end
  end

  describe "error cases" do
    it "raises DeliveryError when template is missing" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "email"))
        File.write(File.join(dir, "email", "has_template.html.erb"), "exists")
        create_template(dir, "email", "missing_tpl.html.erb", content: "placeholder")
        Notify.build_registry!(dir)

        File.delete(File.join(dir, "email", "missing_tpl.html.erb"))

        register_email_adapter

        Notify.configure do |c|
          c.messages[:missing_tpl] = { email_recipients: ["r@test.com"], subject: "Missing" }
        end

        expect { Notify.message(:missing_tpl) }.to raise_error(Notify::DeliveryError)
      end
    end
  end

  describe "recipient arrayification" do
    it "converts a single string recipient to an array" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "single_recip.html.erb", content: "body")
        Notify.build_registry!(dir)
        register_email_adapter

        Notify.message(:single_recip, email_to: "single@test.com", subject: "S")

        expect(ActionMailer::Base.deliveries.last.to).to eq(["single@test.com"])
      end
    end
  end
end
