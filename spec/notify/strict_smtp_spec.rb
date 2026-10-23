# frozen_string_literal: true

require "notify"
require "tmpdir"
require "socket"
require "fileutils"
require "stringio"

RSpec.describe "strict SMTP delivery" do
  let(:rejection) { nil }
  let(:drop_after_data) { false }
  let(:quit_response) { "221 Bye" }
  let(:received) { Queue.new }
  let(:smtp_connection) { instance_double(Mail::SMTPConnection) }
  let(:server) { TCPServer.new("127.0.0.1", 0) }
  let(:port) { server.addr[1] }
  let(:options) { { via: :email, to: "one@example.com", subject: "Private subject", locals: { text: "Private body" },
    message_id: "stable@example.com", delivery_options: { open_timeout: 2, read_timeout: 2 } } }

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      FileUtils.mkdir_p(File.join(directory, "email"))
      File.write(File.join(directory, "email", "alert.text.erb"), "<%= @text %>")
      previous_method = Notify::Mailer.delivery_method
      previous_settings = Notify::Mailer.smtp_settings
      example.run
    ensure
      Notify::Mailer.delivery_method = previous_method
      Notify::Mailer.smtp_settings = previous_settings
      server.close
      @thread&.join(1) || @thread&.kill
    end
  end

  before do
    Notify.build_registry!(@directory)
    Notify.register_adapter(:email, Notify::Adapters::Email)
    Notify.config.adapters[:email][:from] = "sender@example.com"
    Notify::Mailer.delivery_method = :smtp
    Notify::Mailer.perform_deliveries = true
    Notify::Mailer.raise_delivery_errors = true
    Notify::Mailer.smtp_settings = { address: "127.0.0.1", port: port, domain: "example.com", enable_starttls_auto: false }
    @thread = Thread.new do
      socket = server.accept
      socket.write("220 localhost SMTP\r\n")
      while (line = socket.gets)
        case line
        when /\AEHLO/, /\AHELO/ then socket.write("250 localhost\r\n")
        when /\AMAIL/ then socket.write("250 OK\r\n")
        when /\ARCPT/ then socket.write(rejection ? "#{rejection} Private SMTP rejection for one@example.com\r\n" : "250 OK\r\n")
        when /\ADATA/
          socket.write("354 Send data\r\n")
          data = +""
          while (body_line = socket.gets) && body_line != ".\r\n"
            data << body_line
          end
          received << data
          break if drop_after_data

          socket.write("250 Accepted\r\n")
        when /\AQUIT/
          socket.write("#{quit_response}\r\n")
          break
        else socket.write("250 OK\r\n")
        end
      end
    rescue IOError, Errno::EBADF
      nil # The example may deliberately fail before opening a connection.
    ensure
      socket&.close
    end
  end

  it "prepares without sending and only reports accepted after a real SMTP transaction" do
    prepared = Notify.prepare(:alert, **options)
    expect(received).to be_empty
    result = prepared.call
    expect(result.status).to eq(:accepted)
    expect(result.provider_id).to eq("stable@example.com")
    expect(received.pop).to include("Message-ID: <stable@example.com>", "Private body")
  end

  it "does not expose recipients or content in delivery instrumentation" do
    events = []
    subscription = ActiveSupport::Notifications.subscribe("deliver.action_mailer") { |*args| events << args.last }
    Notify.deliver(:alert, **options)
    expect(events.size).to eq(1)
    expect(events.first.to_s).not_to include("Private body", "Private subject", "one@example.com", "sender@example.com")
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  context "with a temporary RCPT rejection" do
    let(:rejection) { 450 }

    it "classifies a definite refusal as retryable without leaking the SMTP response" do
      expect { Notify.deliver(:alert, **options) }.to raise_error(Notify::DeliveryFailure) { |error|
        expect(error.disposition).to eq(:retryable)
        expect(error.cause).to be_nil
      }
    end
  end

  context "with a permanent RCPT rejection" do
    let(:rejection) { 550 }

    it "classifies a definite refusal as permanent" do
      expect { Notify.deliver(:alert, **options) }.to raise_error(Notify::DeliveryFailure) { |error|
        expect(error.disposition).to eq(:permanent)
      }
    end

    it "redacts preparation and failure telemetry before framework subscribers log it" do
      events = []
      subscription = ActiveSupport::Notifications.subscribe(/(?:process|deliver)\.action_mailer/) { |*args| events << args.last }
      previous_logger = ActionMailer::Base.logger
      output = StringIO.new
      ActionMailer::Base.logger = Logger.new(output)
      expect { Notify.deliver(:alert, **options) }.to raise_error(Notify::DeliveryFailure, "smtp_rejected")
      exposed = events.map(&:to_s).join + output.string
      expect(events.size).to eq(2)
      expect(exposed).not_to include("Private SMTP rejection", "one@example.com", "Private subject", "Private body")
      expect(events.last[:exception_object].cause).to be_nil
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
      ActionMailer::Base.logger = previous_logger
    end
  end

  context "when the server drops the response after receiving the message" do
    let(:drop_after_data) { true }

    it "preserves uncertainty instead of enabling an automatic resend" do
      expect { Notify.deliver(:alert, **options) }.to raise_error(Notify::DeliveryFailure) { |error|
        expect(error.disposition).to eq(:uncertain)
      }
      expect(received).not_to be_empty
    end
  end

  ["450 Teardown rejected", "550 Teardown rejected"].each do |reply|
    context "when QUIT returns #{reply}" do
      let(:quit_response) { reply }

      it "preserves the successful DATA acceptance instead of allowing a resend" do
        result = Notify.deliver(:alert, **options)
        expect(result.status).to eq(:accepted)
        expect(received.pop).to include("Private body")
      end
    end
  end

  context "when an established SMTP session loses its route" do
    before do
      allow(Mail::SMTPConnection).to receive(:new).with(connection: instance_of(Net::SMTP), return_response: true)
        .and_return(smtp_connection)
      allow(smtp_connection).to receive(:deliver!).with(instance_of(Mail::Message)).and_raise(Errno::EHOSTUNREACH)
    end

    it "does not mistake a mid-session network failure for a safe initial-connect failure" do
      expect { Notify.deliver(:alert, **options) }.to raise_error(Notify::DeliveryFailure) { |error|
        expect([error.code, error.disposition, error.cause]).to eq(["smtp_outcome_unknown", :uncertain, nil])
      }
    end
  end
end
