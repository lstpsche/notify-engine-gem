# frozen_string_literal: true

require "notify"
require "action_mailer"
require "tmpdir"
require "fileutils"

ActionMailer::Base.delivery_method = :test

RSpec.describe Notify::Mailer do
  let(:logger) { Logger.new(IO::NULL) }

  before do
    ActionMailer::Base.deliveries.clear
    allow(Rails).to receive(:logger).and_return(logger)
  end

  def with_template_dir
    Dir.mktmpdir { |dir| yield dir }
  end

  def deliver(message_name, template_path:, **opts)
    defaults = { locals: {}, to: ["test@example.com"], subject: "Test Subject", from: "noreply@test.com" }
    described_class.dispatch(message_name, template_path: template_path, **defaults.merge(opts)).deliver_now
  end

  describe "instance variable bridge" do
    it "sets instance variables from locals hash" do
      with_template_dir do |dir|
        File.write(File.join(dir, "ivar_test.html.erb"), "<%= @greeting %>")

        deliver(:ivar_test, template_path: dir, locals: { greeting: "hello" })

        expect(ActionMailer::Base.deliveries.last.body.to_s).to include("hello")
      end
    end

    it "skips underscore-prefixed keys and logs a warning" do
      with_template_dir do |dir|
        File.write(File.join(dir, "skip_test.html.erb"), "safe")

        expect(logger).to receive(:warn).with(/Skipping local '_internal'/)

        deliver(:skip_test, template_path: dir, locals: { _internal: "secret", safe: "ok" })
      end
    end

    it "preserves nil values as instance variables" do
      with_template_dir do |dir|
        File.write(File.join(dir, "nil_test.html.erb"), "<%= @missing.nil? ? 'was_nil' : 'not_nil' %>")

        deliver(:nil_test, template_path: dir, locals: { missing: nil })

        expect(ActionMailer::Base.deliveries.last.body.to_s).to include("was_nil")
      end
    end

    it "handles string keys the same as symbol keys" do
      with_template_dir do |dir|
        File.write(File.join(dir, "string_key.html.erb"), "<%= @string_key %>")

        deliver(:string_key, template_path: dir, locals: { "string_key" => "from_string" })

        expect(ActionMailer::Base.deliveries.last.body.to_s).to include("from_string")
      end
    end

    it "handles empty locals hash without error" do
      with_template_dir do |dir|
        File.write(File.join(dir, "empty_locals.html.erb"), "static content")

        expect { deliver(:empty_locals, template_path: dir, locals: {}) }.not_to raise_error

        expect(ActionMailer::Base.deliveries.last.body.to_s).to include("static content")
      end
    end

    it "handles nil locals gracefully" do
      with_template_dir do |dir|
        File.write(File.join(dir, "nil_locals.html.erb"), "static content")

        expect { deliver(:nil_locals, template_path: dir, locals: nil) }.not_to raise_error
      end
    end
  end

  describe "template rendering" do
    it "renders a template using instance variables from locals" do
      with_template_dir do |dir|
        File.write(File.join(dir, "render_test.html.erb"), "<h1><%= @title %></h1><p><%= @body_text %></p>")

        deliver(:render_test, template_path: dir, locals: { title: "Hello", body_text: "World" })

        body = ActionMailer::Base.deliveries.last.body.to_s
        expect(body).to include("<h1>Hello</h1>")
        expect(body).to include("<p>World</p>")
      end
    end

    it "renders multipart email when both html and text templates exist" do
      with_template_dir do |dir|
        File.write(File.join(dir, "multipart.html.erb"), "<b><%= @data %></b>")
        File.write(File.join(dir, "multipart.text.erb"), "Plain: <%= @data %>")

        deliver(:multipart, template_path: dir, locals: { data: "content" })

        mail = ActionMailer::Base.deliveries.last
        expect(mail.parts.size).to eq(2)
        expect(mail.html_part.body.to_s).to include("<b>content</b>")
        expect(mail.text_part.body.to_s).to include("Plain: content")
      end
    end

    it "uses message_name as template_name (not action name)" do
      with_template_dir do |dir|
        File.write(File.join(dir, "custom_name.html.erb"), "found")

        deliver(:custom_name, template_path: dir)

        expect(ActionMailer::Base.deliveries.last.body.to_s).to include("found")
      end
    end
  end

  describe "mail options" do
    it "sets subject correctly" do
      with_template_dir do |dir|
        File.write(File.join(dir, "subj.html.erb"), "body")

        deliver(:subj, template_path: dir, subject: "My Subject")

        expect(ActionMailer::Base.deliveries.last.subject).to eq("My Subject")
      end
    end

    it "sets recipients correctly" do
      with_template_dir do |dir|
        File.write(File.join(dir, "recip.html.erb"), "body")

        deliver(:recip, template_path: dir, to: ["a@test.com", "b@test.com"])

        expect(ActionMailer::Base.deliveries.last.to).to eq(["a@test.com", "b@test.com"])
      end
    end

    it "includes from when provided" do
      with_template_dir do |dir|
        File.write(File.join(dir, "from.html.erb"), "body")

        deliver(:from, template_path: dir, from: "sender@test.com")

        expect(ActionMailer::Base.deliveries.last.from).to eq(["sender@test.com"])
      end
    end

    it "does not include from header when from is nil" do
      with_template_dir do |dir|
        File.write(File.join(dir, "no_from.html.erb"), "body")

        message = described_class.dispatch(:no_from,
          locals: {}, to: ["test@example.com"], subject: "Test", from: nil, template_path: dir)

        expect(message.from).to be_nil
      end
    end

    it "includes cc when provided" do
      with_template_dir do |dir|
        File.write(File.join(dir, "cc.html.erb"), "body")

        deliver(:cc, template_path: dir, cc: ["cc@test.com"])

        expect(ActionMailer::Base.deliveries.last.cc).to eq(["cc@test.com"])
      end
    end

    it "includes bcc when provided" do
      with_template_dir do |dir|
        File.write(File.join(dir, "bcc.html.erb"), "body")

        deliver(:bcc, template_path: dir, bcc: ["bcc@test.com"])

        expect(ActionMailer::Base.deliveries.last.bcc).to eq(["bcc@test.com"])
      end
    end

    it "omits cc and bcc when nil" do
      with_template_dir do |dir|
        File.write(File.join(dir, "no_cc_bcc.html.erb"), "body")

        deliver(:no_cc_bcc, template_path: dir, cc: nil, bcc: nil)

        mail = ActionMailer::Base.deliveries.last
        expect(mail.cc).to be_nil
        expect(mail.bcc).to be_nil
      end
    end
  end

  describe "view path" do
    it "renders from the specified template_path directory" do
      with_template_dir do |dir|
        subdir = File.join(dir, "nested")
        FileUtils.mkdir_p(subdir)
        File.write(File.join(subdir, "nested_msg.html.erb"), "found in nested")

        deliver(:nested_msg, template_path: subdir)

        expect(ActionMailer::Base.deliveries.last.body.to_s).to include("found in nested")
      end
    end
  end
end
