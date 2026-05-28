# frozen_string_literal: true

require "notify"
require "fileutils"
require "tmpdir"

RSpec.describe Notify::Registry do
  def create_template(base, *path_parts)
    full_path = File.join(base, *path_parts)
    FileUtils.mkdir_p(File.dirname(full_path))
    FileUtils.touch(full_path)
  end

  describe "basic scanning" do
    it "discovers a single message in a single adapter directory" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "welcome.html.erb")

        registry = described_class.new(dir)

        expect(registry.messages).to eq(welcome: [:email])
      end
    end

    it "discovers messages across multiple adapter directories" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "alert.html.erb")
        create_template(dir, "telegram", "alert.md.erb")

        registry = described_class.new(dir)

        expect(registry.messages).to eq(alert: %i[email telegram])
      end
    end

    it "discovers multiple messages within one adapter" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "alert.html.erb")
        create_template(dir, "email", "report.html.erb")

        registry = described_class.new(dir)

        expect(registry.messages).to eq(alert: [:email], report: [:email])
      end
    end

    it "returns empty results for an empty directory" do
      Dir.mktmpdir do |dir|
        registry = described_class.new(dir)

        expect(registry.messages).to eq({})
        expect(registry.adapters).to eq({})
      end
    end

    it "returns empty results for a nonexistent path" do
      registry = described_class.new("/tmp/notify_nonexistent_#{Process.pid}")

      expect(registry.messages).to eq({})
      expect(registry.adapters).to eq({})
    end
  end

  describe "multipart de-duplication" do
    it "treats .html.erb and .text.erb as one message" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "welcome.html.erb")
        create_template(dir, "email", "welcome.text.erb")

        registry = described_class.new(dir)

        expect(registry.messages).to eq(welcome: [:email])
      end
    end

    it "de-duplicates across multiple format variants" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "report.html.erb")
        create_template(dir, "email", "report.text.erb")
        create_template(dir, "email", "report.json.erb")

        registry = described_class.new(dir)

        expect(registry.messages).to eq(report: [:email])
      end
    end
  end

  describe "_ prefix exclusion" do
    it "excludes files starting with _" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "_disabled.html.erb")

        registry = described_class.new(dir)

        expect(registry.messages).to eq({})
      end
    end

    it "includes non-prefixed files alongside _-prefixed ones" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "enabled.html.erb")
        create_template(dir, "email", "_disabled.html.erb")

        registry = described_class.new(dir)

        expect(registry.messages).to eq(enabled: [:email])
      end
    end
  end

  describe "format-agnostic extension stripping" do
    it "strips .html.erb to get the message name" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "report.html.erb")

        registry = described_class.new(dir)

        expect(registry.messages.keys).to eq([:report])
      end
    end

    it "strips .erb alone when no format segment exists" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "report.erb")

        registry = described_class.new(dir)

        expect(registry.messages.keys).to eq([:report])
      end
    end

    it "strips .md.erb (non-standard format)" do
      Dir.mktmpdir do |dir|
        create_template(dir, "telegram", "alert.md.erb")

        registry = described_class.new(dir)

        expect(registry.messages.keys).to eq([:alert])
      end
    end

    it "discovers .builder templates (proves non-hardcoded handler list)" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "feed.html.builder")

        registry = described_class.new(dir)

        expect(registry.messages.keys).to eq([:feed])
      end
    end

    it "produces the same message name from .html.erb and .md.erb across adapters" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "alert.html.erb")
        create_template(dir, "telegram", "alert.md.erb")

        registry = described_class.new(dir)

        expect(registry.messages).to eq(alert: %i[email telegram])
      end
    end

    it "preserves dots in message names when multiple dots precede format.handler" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "v2.report.html.erb")

        registry = described_class.new(dir)

        expect(registry.messages.keys).to eq([:"v2.report"])
      end
    end

    it "uses ActionView::Template::Handlers.extensions as the handler source" do
      extensions = ActionView::Template::Handlers.extensions
      expect(extensions).to include(:erb)
      expect(extensions).to include(:builder)
    end
  end

  describe "non-template file handling" do
    it "ignores files without recognized handler extensions" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "notes.txt")
        create_template(dir, "email", "README.md")
        create_template(dir, "email", ".keep")

        registry = described_class.new(dir)

        expect(registry.messages).to eq({})
      end
    end

    it "ignores .rb files in adapter directories" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "helper.rb")

        registry = described_class.new(dir)

        expect(registry.messages).to eq({})
      end
    end

    it "ignores subdirectories within adapter directories" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "nested", "deep.html.erb")
        create_template(dir, "email", "surface.html.erb")

        registry = described_class.new(dir)

        expect(registry.messages).to eq(surface: [:email])
      end
    end

    it "ignores files at the root of templates_path" do
      Dir.mktmpdir do |dir|
        create_template(dir, "root_file.html.erb")
        create_template(dir, "payload.rb")
        create_template(dir, "email", "real.html.erb")

        registry = described_class.new(dir)

        expect(registry.messages).to eq(real: [:email])
      end
    end

    it "ignores files with no extension" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "Makefile")

        registry = described_class.new(dir)

        expect(registry.messages).to eq({})
      end
    end
  end

  describe "sorting" do
    it "sorts message keys alphabetically" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "zebra.html.erb")
        create_template(dir, "email", "alpha.html.erb")
        create_template(dir, "email", "middle.html.erb")

        registry = described_class.new(dir)

        expect(registry.messages.keys).to eq(%i[alpha middle zebra])
      end
    end

    it "sorts adapter arrays within each message" do
      Dir.mktmpdir do |dir|
        create_template(dir, "telegram", "alert.md.erb")
        create_template(dir, "email", "alert.html.erb")
        create_template(dir, "slack", "alert.html.erb")

        registry = described_class.new(dir)

        expect(registry.messages[:alert]).to eq(%i[email slack telegram])
      end
    end

    it "sorts adapter keys in the adapters view" do
      Dir.mktmpdir do |dir|
        create_template(dir, "telegram", "alert.md.erb")
        create_template(dir, "email", "alert.html.erb")

        registry = described_class.new(dir)

        expect(registry.adapters.keys).to eq(%i[email telegram])
      end
    end

    it "sorts message arrays within each adapter" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "zebra.html.erb")
        create_template(dir, "email", "alpha.html.erb")

        registry = described_class.new(dir)

        expect(registry.adapters[:email]).to eq(%i[alpha zebra])
      end
    end
  end

  describe "query methods" do
    it "message? returns true for known messages" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "welcome.html.erb")

        registry = described_class.new(dir)

        expect(registry.message?(:welcome)).to be true
        expect(registry.message?("welcome")).to be true
      end
    end

    it "message? returns false for unknown messages" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "welcome.html.erb")

        registry = described_class.new(dir)

        expect(registry.message?(:unknown)).to be false
      end
    end

    it "adapters_for returns the adapter list for a known message" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "alert.html.erb")
        create_template(dir, "telegram", "alert.md.erb")

        registry = described_class.new(dir)

        expect(registry.adapters_for(:alert)).to eq(%i[email telegram])
      end
    end

    it "adapters_for returns an empty frozen array for unknown messages" do
      Dir.mktmpdir do |dir|
        registry = described_class.new(dir)

        result = registry.adapters_for(:unknown)
        expect(result).to eq([])
        expect(result).to be_frozen
      end
    end

    it "adapters returns the inverse mapping" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "alert.html.erb")
        create_template(dir, "email", "report.html.erb")
        create_template(dir, "telegram", "alert.md.erb")

        registry = described_class.new(dir)

        expect(registry.adapters).to eq(
          email: %i[alert report],
          telegram: [:alert]
        )
      end
    end
  end

  describe "freeze" do
    it "is not frozen by default" do
      Dir.mktmpdir do |dir|
        registry = described_class.new(dir)

        expect(registry).not_to be_frozen
      end
    end

    it "becomes frozen after freeze!" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "alert.html.erb")

        registry = described_class.new(dir)
        registry.freeze!

        expect(registry).to be_frozen
      end
    end

    it "returns self from freeze! for chaining" do
      Dir.mktmpdir do |dir|
        registry = described_class.new(dir)

        expect(registry.freeze!).to be(registry)
      end
    end

    it "still returns correct query results after freeze" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "alert.html.erb")
        create_template(dir, "telegram", "alert.md.erb")

        registry = described_class.new(dir)
        registry.freeze!

        expect(registry.messages).to eq(alert: %i[email telegram])
        expect(registry.adapters).to eq(email: [:alert], telegram: [:alert])
        expect(registry.message?(:alert)).to be true
        expect(registry.adapters_for(:alert)).to eq(%i[email telegram])
      end
    end

    it "returns frozen query results" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "alert.html.erb")

        registry = described_class.new(dir)

        expect(registry.messages).to be_frozen
        expect(registry.messages[:alert]).to be_frozen
        expect(registry.adapters).to be_frozen
        expect(registry.adapters[:email]).to be_frozen
      end
    end
  end

  describe "adapter directory with no valid templates" do
    it "does not appear in adapters when dir has only _-prefixed files" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "_disabled.html.erb")

        registry = described_class.new(dir)

        expect(registry.adapters).to eq({})
      end
    end

    it "does not appear in adapters when dir has only non-template files" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "notes.txt")

        registry = described_class.new(dir)

        expect(registry.adapters).to eq({})
      end
    end
  end

  describe "custom adapter directories" do
    it "discovers custom adapter directories without registered adapter classes" do
      Dir.mktmpdir do |dir|
        create_template(dir, "slack", "alert.html.erb")
        create_template(dir, "webhook", "alert.html.erb")

        registry = described_class.new(dir)

        expect(registry.messages).to eq(alert: %i[slack webhook])
        expect(registry.adapters.keys).to include(:slack, :webhook)
      end
    end
  end
end
