# frozen_string_literal: true

require "notify"
require "tmpdir"
require "fileutils"
require "webmock/rspec"

RSpec.describe "strict notification delivery" do
  let(:token) { "123456:example_test_token" }
  let(:destination) { { bot: :alerts, chat_id: "@example_channel" } }
  let(:endpoint) { "https://api.telegram.org/bot#{token}/sendMessage" }
  let(:options) { { via: :telegram, to: destination, locals: { text: "Привіт <world> & 👋" } } }
  let(:interceptor) { double("Mail interceptor") }
  let(:custom_transport) { double("Custom transport") }
  let(:custom_transport_class) { Class.new }

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      FileUtils.mkdir_p(File.join(directory, "telegram"))
      FileUtils.mkdir_p(File.join(directory, "email"))
      File.write(File.join(directory, "telegram", "alert.text.erb"), "<%= text %>")
      File.write(File.join(directory, "email", "alert.text.erb"), "<%= @text %>")
      example.run
    end
  end

  before do
    Notify.build_registry!(@directory)
    Notify.register_adapter(:telegram, Notify::Adapters::Telegram)
    Notify.register_adapter(:email, Notify::Adapters::Email)
    Notify.config.adapters[:telegram] = { enabled: true, bots: [{ name: :alerts, token: -> { token } }] }
    Notify.config.adapters[:email][:from] = "sender@example.com"
    ActionMailer::Base.delivery_method = :test
    ActionMailer::Base.perform_deliveries = true
    ActionMailer::Base.raise_delivery_errors = true
    Notify::Mailer.perform_deliveries = true
    Notify::Mailer.raise_delivery_errors = true
  end

  it "sends one explicit target with plain Unicode text and returns Telegram acceptance" do
    request = stub_request(:post, endpoint).with do |http|
      JSON.parse(http.body) == { "chat_id" => "@example_channel", "text" => "Привіт <world> & 👋",
        "link_preview_options" => { "is_disabled" => true } }
    end.to_return(status: 200, body: '{"ok":true,"result":{"message_id":15}}')
    result = Notify.deliver(:alert, **options)
    expect(result.to_h).to eq(adapter: :telegram, status: :accepted, provider_id: "15")
    expect(request).to have_been_requested.once
  end

  {
    "Forbidden: bot is not a member of the channel chat" => "bot_not_member",
    "Forbidden: bot was blocked by the user" => "bot_blocked",
    "Bad Request: chat not found" => "chat_unavailable",
    "Bad Request: not enough rights to send text messages to the chat" => "posting_forbidden",
    "unrecognized sensitive provider detail" => "telegram_rejected"
  }.each do |description, code|
    it "exposes safe #{code} without retaining raw descriptions or causes" do
      stub_request(:post, endpoint).to_return(status: 403,
        body: JSON.generate(ok: false, error_code: 403, description: description))
      expect { Notify.deliver(:alert, **options) }.to raise_error(Notify::DeliveryFailure) { |error|
        expect([error.code, error.disposition, error.cause]).to eq([code, :permanent, nil])
        expect(error.full_message).not_to include(token, description)
      }
    end
  end

  it "returns a provider rate delay without hidden retries" do
    request = stub_request(:post, endpoint).to_return(status: 429,
      body: '{"ok":false,"error_code":429,"parameters":{"retry_after":47}}')
    expect { Notify.deliver(:alert, **options) }.to raise_error(Notify::DeliveryFailure) { |error|
      expect([error.disposition, error.retry_after]).to eq([:retryable, 47])
    }
    expect(request).to have_been_requested.once
  end

  ["invalid", '{"ok":true,"result":{}}', '{}', '[]'].each do |body|
    it "preserves uncertainty for an unusable response #{body.inspect}" do
      stub_request(:post, endpoint).to_return(status: 200, body: body)
      expect { Notify.deliver(:alert, **options) }.to raise_error(Notify::DeliveryFailure) { |error|
        expect(error.disposition).to eq(:uncertain)
      }
    end
  end

  it "does not retry an ambiguous read timeout" do
    request = stub_request(:post, endpoint).to_timeout
    expect { Notify.deliver(:alert, **options) }.to raise_error(Notify::DeliveryFailure) { |error|
      expect(error.disposition).to eq(:uncertain)
      expect(error.cause).to be_nil
    }
    expect(request).to have_been_requested.once
  end

  it "captures explicit targets without claiming provider acceptance" do
    Notify.test_mode!
    result = Notify.deliver(:alert, **options)
    expect(result.status).to eq(:captured)
    expect(Notify.deliveries.last[:resolved][:recipients]).to eq(telegram: [destination])
    expect(WebMock).not_to have_requested(:post, endpoint)
  end

  it "never falls back to default targets" do
    Notify.config.adapters[:email][:default_recipients] = ["default@example.com"]
    expect { Notify.deliver(:alert, via: :email, to: nil, subject: "Hello") }
      .to raise_error(Notify::DeliveryFailure, "invalid_recipient")
  end

  it "rejects email lists and header injection" do
    ["one@example.com,two@example.com", "one@example.com\r\nBcc: two@example.com"].each do |recipient|
      expect { Notify.deliver(:alert, via: :email, to: recipient, subject: "Hello") }
        .to raise_error(Notify::DeliveryFailure, "invalid_recipient")
    end
  end

  it "does not call a disabled or unknown bot" do
    Notify.config.adapters[:telegram][:bots] = []
    expect { Notify.deliver(:alert, **options) }.to raise_error(Notify::DeliveryFailure, "unknown_bot")
    expect(WebMock).not_to have_requested(:post, endpoint)
  end

  it "marks the real ActionMailer test transport as captured and preserves a stable Message-ID" do
    result = Notify.deliver(:alert, via: :email, to: "one@example.com", subject: "Hello", locals: { text: "content" },
      message_id: "stable@example.com", delivery_options: { open_timeout: 5, read_timeout: 15 })
    expect(result.status).to eq(:captured)
    mail = ActionMailer::Base.deliveries.last
    expect(mail.to).to eq(["one@example.com"])
    expect(mail.message_id).to eq("stable@example.com")
    expect(mail.delivery_method.settings).to include(open_timeout: 5, read_timeout: 15)
  end

  it "does not claim suppressed delivery as accepted" do
    Notify::Mailer.perform_deliveries = false
    expect { Notify.deliver(:alert, via: :email, to: "one@example.com", subject: "Hello", locals: { text: "content" }) }
      .to raise_error(Notify::DeliveryFailure, "delivery_suppressed")
  ensure
    Notify::Mailer.perform_deliveries = true
  end

  it "snapshots the prepared Telegram destination before a caller mutates the input" do
    destination[:chat_id] = destination[:chat_id].dup
    request = stub_request(:post, endpoint).with { |http| JSON.parse(http.body)["chat_id"] == "@example_channel" }
      .to_return(status: 200, body: '{"ok":true,"result":{"message_id":15}}')
    prepared = Notify.prepare(:alert, **options)
    destination[:chat_id].replace("@another_channel")
    expect(prepared.call.status).to eq(:accepted)
    expect(request).to have_been_requested.once
  end

  it "rejects unbounded transport timeouts before opening a connection" do
    Notify.config.adapters[:telegram][:read_timeout] = Float::INFINITY
    expect { Notify.prepare(:alert, **options) }.to raise_error(Notify::DeliveryFailure, "invalid_delivery_options")
    expect(WebMock).not_to have_requested(:post, endpoint)
  end

  it "restricts the Message-ID option to email" do
    expect { Notify.prepare(:alert, **options, message_id: "stable@example.com") }
      .to raise_error(Notify::DeliveryFailure, "invalid_message_id")
  end

  it "sanitizes unexpected configuration exceptions and reports the failure once" do
    Notify.config.adapters[:telegram][:bots] = nil
    events = []
    subscription = ActiveSupport::Notifications.subscribe("notify.adapter.error") { |*args| events << args.last }
    expect { Notify.prepare(:alert, **options) }.to raise_error(Notify::DeliveryFailure) { |error|
      expect(error.code).to eq("preparation_failed")
      expect(error.cause).to be_nil
      expect(error.full_message).not_to include(token)
    }
    expect(events.size).to eq(1)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  it "does not inherit default CC or BCC recipients for a strict send" do
    previous_defaults = Notify::Mailer.default_params
    Notify::Mailer.default(cc: "copy@example.com", bcc: "blind@example.com")
    Notify.deliver(:alert, via: :email, to: "one@example.com", subject: "Hello", locals: { text: "content" })
    mail = ActionMailer::Base.deliveries.last
    expect(mail.destinations).to eq(["one@example.com"])
  ensure
    Notify::Mailer.default_params = previous_defaults
  end

  it "enqueues a serializable strict email and reports enqueue separately from acceptance" do
    previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :inline
    result = Notify.deliver(:alert, via: :email, to: "one@example.com", subject: "Hello",
      locals: { text: "async body" }, delivery_method: :deliver_later)
    expect(result.status).to eq(:enqueued)
    mail = ActionMailer::Base.deliveries.last
    expect(mail.to).to eq(["one@example.com"])
    expect(mail.body.to_s).to include("async body")
  ensure
    ActiveJob::Base.queue_adapter = previous_adapter
  end

  context "with a suppressing mail interceptor" do
    before do
      allow(interceptor).to receive(:delivering_email) { |mail| mail.perform_deliveries = false }
      Mail.register_interceptor(interceptor)
    end

    after { Mail.unregister_interceptor(interceptor) }

    it "does not call suppressed mail accepted" do
      expect { Notify.deliver(:alert, via: :email, to: "one@example.com", subject: "Hello", locals: { text: "body" }) }
        .to raise_error(Notify::DeliveryFailure, "delivery_suppressed")
    end
  end

  { to: "redirected@example.com", bcc: "copy@example.com", smtp_envelope_to: "envelope@example.com" }.each do |field, address|
    context "when an interceptor changes #{field}" do
      before do
        allow(interceptor).to receive(:delivering_email) { |mail| mail.public_send("#{field}=", address) }
        Mail.register_interceptor(interceptor)
      end

      after { Mail.unregister_interceptor(interceptor) }

      it "rejects a changed destination before the transport executes" do
        expect { Notify.deliver(:alert, via: :email, to: "one@example.com", subject: "Hello",
          locals: { text: "body", strict_recipient: address }) }
          .to raise_error(Notify::DeliveryFailure) { |error|
            expect([error.code, error.attempted]).to eq(["recipient_changed", false])
          }
      end
    end
  end

  context "when an interceptor changes the mail transport" do
    before do
      allow(custom_transport_class).to receive(:new).with(any_args).and_return(custom_transport)
      allow(interceptor).to receive(:delivering_email) { |mail| mail.delivery_method(custom_transport_class) }
      Mail.register_interceptor(interceptor)
    end

    after { Mail.unregister_interceptor(interceptor) }

    it "rejects the unsupported transport without invoking it" do
      expect(custom_transport).not_to receive(:deliver!)
      expect { Notify.deliver(:alert, via: :email, to: "one@example.com", subject: "Hello", locals: { text: "body" }) }
        .to raise_error(Notify::DeliveryFailure, "unsupported_email_transport")
    end
  end

  context "when an interceptor disables delivery error reporting" do
    before do
      allow(interceptor).to receive(:delivering_email) { |mail| mail.raise_delivery_errors = false }
      Mail.register_interceptor(interceptor)
    end

    after { Mail.unregister_interceptor(interceptor) }

    it "stops before a transport with disabled error reporting can run" do
      expect { Notify.deliver(:alert, via: :email, to: "one@example.com", subject: "Hello", locals: { text: "body" }) }
        .to raise_error(Notify::DeliveryFailure) { |error|
          expect([error.code, error.disposition, error.attempted]).to eq(["delivery_errors_disabled", :permanent, false])
        }
    end
  end
end
