# frozen_string_literal: true

require "notify"

RSpec.describe Notify::TestHelper do
  include Notify::TestHelper

  before do
    Notify.test_mode!
  end

  def sample_delivery(name, recipients: { email: ["user@test.com"] }, subject: "Test Subject")
    {
      name: name.to_sym,
      adapters: recipients.keys,
      payload: { data: "value" },
      resolved: {
        subject: subject,
        recipients: recipients,
        locals: { data: "value" }
      }
    }
  end

  describe "#assert_notify_dispatched" do
    context "name matching" do
      it "passes when a matching dispatch exists" do
        Notify.deliveries << sample_delivery(:my_message)

        expect { assert_notify_dispatched(:my_message) }.not_to raise_error
      end

      it "raises when no matching dispatch exists" do
        Notify.deliveries << sample_delivery(:other_message)

        expect { assert_notify_dispatched(:missing) }
          .to raise_error(RuntimeError, /Expected Notify.message\(:missing\) to have been dispatched/)
      end

      it "includes delivery names in failure message" do
        Notify.deliveries << sample_delivery(:alpha)
        Notify.deliveries << sample_delivery(:beta)

        expect { assert_notify_dispatched(:missing) }
          .to raise_error(RuntimeError, /Deliveries:.*alpha.*beta/)
      end
    end

    context "count assertion" do
      it "passes with correct count" do
        2.times { Notify.deliveries << sample_delivery(:counted) }

        expect { assert_notify_dispatched(:counted, count: 2) }.not_to raise_error
      end

      it "raises with wrong count" do
        Notify.deliveries << sample_delivery(:counted)

        expect { assert_notify_dispatched(:counted, count: 3) }
          .to raise_error(RuntimeError, /Expected 3 dispatch\(es\) of :counted, got 1/)
      end
    end

    context "recipient assertion" do
      it "passes when recipients match" do
        Notify.deliveries << sample_delivery(:recip_test, recipients: { email: ["a@t.com", "b@t.com"] })

        expect { assert_notify_dispatched(:recip_test, to: ["a@t.com"]) }.not_to raise_error
      end

      it "passes when recipients match across adapters" do
        Notify.deliveries << sample_delivery(
          :multi_recip,
          recipients: { email: ["e@t.com"], telegram: ["bot1"] }
        )

        expect { assert_notify_dispatched(:multi_recip, to: ["e@t.com", "bot1"]) }.not_to raise_error
      end

      it "raises when recipients don't match" do
        Notify.deliveries << sample_delivery(:recip_test, recipients: { email: ["a@t.com"] })

        expect { assert_notify_dispatched(:recip_test, to: ["missing@t.com"]) }
          .to raise_error(RuntimeError, /Expected recipients.*missing@t.com.*not found/)
      end

      it "accepts a single recipient (non-array)" do
        Notify.deliveries << sample_delivery(:single_recip, recipients: { email: ["user@t.com"] })

        expect { assert_notify_dispatched(:single_recip, to: "user@t.com") }.not_to raise_error
      end
    end

    it "returns true on success" do
      Notify.deliveries << sample_delivery(:return_val)

      expect(assert_notify_dispatched(:return_val)).to be true
    end
  end

  describe "#last_notify_delivery" do
    it "returns the last delivery" do
      Notify.deliveries << sample_delivery(:first)
      Notify.deliveries << sample_delivery(:second)

      expect(last_notify_delivery[:name]).to eq(:second)
    end

    it "returns nil when no deliveries" do
      expect(last_notify_delivery).to be_nil
    end
  end

  describe "#setup_notify_test_mode" do
    it "activates test mode and clears deliveries" do
      Notify.deliveries << sample_delivery(:leftover)
      Notify.reset_test_mode!

      setup_notify_test_mode

      expect(Notify.test_mode?).to be true
      expect(Notify.deliveries).to be_empty
    end
  end
end
