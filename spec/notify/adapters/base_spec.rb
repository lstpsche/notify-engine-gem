# frozen_string_literal: true

require "notify"

RSpec.describe Notify::Adapters::Base do
  let(:deliver_kwargs) do
    {
      message_name: :test_message,
      to: ["user@example.com"],
      subject: "Test Subject",
      locals: { key: "value" },
      template_path: Pathname("/tmp/templates/email")
    }
  end

  describe "#deliver" do
    it "raises Notify::NotImplementedError on the base class" do
      expect { described_class.new.deliver(**deliver_kwargs) }
        .to raise_error(Notify::NotImplementedError)
    end

    it "includes the class name in the error message" do
      expect { described_class.new.deliver(**deliver_kwargs) }
        .to raise_error(Notify::NotImplementedError, /Notify::Adapters::Base#deliver must be implemented/)
    end

    it "includes the subclass name in the error message" do
      subclass = Class.new(described_class)
      stub_const("Notify::Adapters::TestAdapter", subclass)

      expect { subclass.new.deliver(**deliver_kwargs) }
        .to raise_error(Notify::NotImplementedError, /Notify::Adapters::TestAdapter#deliver must be implemented/)
    end

    it "accepts all keyword arguments including optional options" do
      adapter = Class.new(described_class) do
        define_method(:deliver) do |message_name:, to:, subject:, locals:, template_path:, options: {}|
          { message_name: message_name, to: to, subject: subject, locals: locals,
            template_path: template_path, options: options }
        end
      end

      result = adapter.new.deliver(**deliver_kwargs)

      expect(result).to eq(deliver_kwargs.merge(options: {}))
    end

    it "passes options through when provided" do
      adapter = Class.new(described_class) do
        define_method(:deliver) do |message_name:, to:, subject:, locals:, template_path:, options: {}|
          options
        end
      end

      result = adapter.new.deliver(**deliver_kwargs, options: { from: "sender@example.com", cc: ["cc@example.com"] })

      expect(result).to eq(from: "sender@example.com", cc: ["cc@example.com"])
    end
  end

  describe ".template_extensions" do
    it "raises Notify::NotImplementedError on the base class" do
      expect { described_class.template_extensions }
        .to raise_error(Notify::NotImplementedError)
    end

    it "includes the class name in the error message" do
      expect { described_class.template_extensions }
        .to raise_error(Notify::NotImplementedError, /Notify::Adapters::Base\.template_extensions must be implemented/)
    end

    it "includes the subclass name in the error message" do
      subclass = Class.new(described_class)
      stub_const("Notify::Adapters::CustomChannel", subclass)

      expect { subclass.template_extensions }
        .to raise_error(Notify::NotImplementedError, /Notify::Adapters::CustomChannel\.template_extensions must be implemented/)
    end

    it "can be overridden by a subclass" do
      subclass = Class.new(described_class) do
        def self.template_extensions
          %i[html text]
        end
      end

      expect(subclass.template_extensions).to eq(%i[html text])
    end
  end

  describe "subclass contract" do
    let(:adapter_class) do
      Class.new(described_class) do
        def self.template_extensions
          %i[erb]
        end

        def deliver(message_name:, to:, subject:, locals:, template_path:, options: {})
          :delivered
        end
      end
    end

    it "can override deliver and return a result" do
      result = adapter_class.new.deliver(**deliver_kwargs)

      expect(result).to eq(:delivered)
    end

    it "can override template_extensions and return extensions" do
      expect(adapter_class.template_extensions).to eq(%i[erb])
    end

    it "inherits from Notify::Adapters::Base" do
      expect(adapter_class.ancestors).to include(described_class)
    end
  end
end
