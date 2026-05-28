# frozen_string_literal: true

require "pathname"
require "fileutils"
require "tmpdir"
require "notify"

RSpec.describe "registry lifecycle" do
  def create_template(base, *path_parts)
    full_path = File.join(base, *path_parts)
    FileUtils.mkdir_p(File.dirname(full_path))
    FileUtils.touch(full_path)
  end

  describe "public API without registry" do
    it "returns empty hash from Notify.messages" do
      expect(Notify.messages).to eq({})
    end

    it "returns empty hash from Notify.adapters" do
      expect(Notify.adapters).to eq({})
    end

    it "returns nil from Notify.registry" do
      expect(Notify.registry).to be_nil
    end
  end

  describe "build_registry! and reset_registry!" do
    it "builds a registry and makes it accessible" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "welcome.html.erb")

        Notify.build_registry!(dir)

        expect(Notify.registry).to be_a(Notify::Registry)
        expect(Notify.messages).to eq(welcome: [:email])
      end
    end

    it "delegates adapters to the registry" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "welcome.html.erb")

        Notify.build_registry!(dir)

        expect(Notify.adapters).to eq(email: [:welcome])
      end
    end

    it "returns the new registry from build_registry!" do
      Dir.mktmpdir do |dir|
        result = Notify.build_registry!(dir)

        expect(result).to be_a(Notify::Registry)
        expect(result).to equal(Notify.registry)
      end
    end

    it "clears the registry on reset_registry!" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "welcome.html.erb")

        Notify.build_registry!(dir)
        expect(Notify.registry).not_to be_nil

        Notify.reset_registry!
        expect(Notify.registry).to be_nil
        expect(Notify.messages).to eq({})
        expect(Notify.adapters).to eq({})
      end
    end
  end

  describe "development reload simulation" do
    it "reflects new templates after rebuild" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "alert.html.erb")
        Notify.build_registry!(dir)

        expect(Notify.messages.keys).to eq([:alert])

        create_template(dir, "email", "report.html.erb")
        Notify.build_registry!(dir)

        expect(Notify.messages.keys).to eq(%i[alert report])
      end
    end

    it "reflects removed templates after rebuild" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "alert.html.erb")
        create_template(dir, "email", "report.html.erb")
        Notify.build_registry!(dir)

        expect(Notify.messages.keys).to eq(%i[alert report])

        File.delete(File.join(dir, "email", "report.html.erb"))
        Notify.build_registry!(dir)

        expect(Notify.messages.keys).to eq([:alert])
      end
    end

    it "reflects new adapter directories after rebuild" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "alert.html.erb")
        Notify.build_registry!(dir)

        expect(Notify.adapters.keys).to eq([:email])

        create_template(dir, "telegram", "alert.md.erb")
        Notify.build_registry!(dir)

        expect(Notify.adapters.keys).to eq(%i[email telegram])
      end
    end
  end

  describe "production freeze" do
    it "freezes the registry" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "alert.html.erb")
        Notify.build_registry!(dir)

        Notify.registry.freeze!

        expect(Notify.registry).to be_frozen
      end
    end

    it "still returns correct queries after freeze" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "alert.html.erb")
        create_template(dir, "telegram", "alert.md.erb")
        Notify.build_registry!(dir)

        Notify.registry.freeze!

        expect(Notify.messages).to eq(alert: %i[email telegram])
        expect(Notify.adapters).to eq(email: [:alert], telegram: [:alert])
      end
    end
  end

  describe "engine initializers" do
    it "defines the registry initializer" do
      initializer = Notify::Engine.initializers.find { |i| i.name == "notify_engine.registry" }

      expect(initializer).not_to be_nil
    end

    it "defines the freeze_registry initializer" do
      initializer = Notify::Engine.initializers.find { |i| i.name == "notify_engine.freeze_registry" }

      expect(initializer).not_to be_nil
    end

    it "registers a to_prepare callback when the registry initializer runs" do
      to_prepare_callbacks = []
      after_initialize_callbacks = []

      app_config = Struct.new(:autoload_paths, :eager_load_paths) do
        define_method(:to_prepare) { |&block| to_prepare_callbacks << block }
        define_method(:after_initialize) { |&block| after_initialize_callbacks << block }
      end.new([], [])

      app = Struct.new(:root, :config).new(Pathname.new("/tmp/notify_test"), app_config)

      initializer = Notify::Engine.initializers.find { |i| i.name == "notify_engine.registry" }
      initializer.run(app)

      expect(to_prepare_callbacks.size).to eq(1)
    end

    it "registers an after_initialize callback for freeze" do
      to_prepare_callbacks = []
      after_initialize_callbacks = []

      app_config = Struct.new(:autoload_paths, :eager_load_paths) do
        define_method(:to_prepare) { |&block| to_prepare_callbacks << block }
        define_method(:after_initialize) { |&block| after_initialize_callbacks << block }
      end.new([], [])

      app = Struct.new(:root, :config).new(Pathname.new("/tmp/notify_test"), app_config)

      initializer = Notify::Engine.initializers.find { |i| i.name == "notify_engine.freeze_registry" }
      initializer.run(app)

      expect(after_initialize_callbacks.size).to eq(1)
    end

    it "builds the registry when the to_prepare callback executes" do
      Dir.mktmpdir do |dir|
        create_template(dir, "app", "notify_templates", "email", "alert.html.erb")

        to_prepare_callbacks = []
        app_config = Struct.new(:autoload_paths, :eager_load_paths) do
          define_method(:to_prepare) { |&block| to_prepare_callbacks << block }
        end.new([], [])

        app = Struct.new(:root, :config).new(Pathname.new(dir), app_config)

        initializer = Notify::Engine.initializers.find { |i| i.name == "notify_engine.registry" }
        initializer.run(app)

        to_prepare_callbacks.each(&:call)

        expect(Notify.registry).to be_a(Notify::Registry)
        expect(Notify.messages).to eq(alert: [:email])
      end
    end
  end

  describe "full integration" do
    it "discovers messages and adapters from a complete template tree" do
      Dir.mktmpdir do |dir|
        create_template(dir, "email", "stuck_pg_jobs.html.erb")
        create_template(dir, "email", "stuck_pg_jobs.text.erb")
        create_template(dir, "email", "export_report.html.erb")
        create_template(dir, "telegram", "stuck_pg_jobs.md.erb")
        create_template(dir, "email", "_disabled_message.html.erb")
        FileUtils.touch(File.join(dir, "stuck_pg_jobs.rb"))

        Notify.build_registry!(dir)

        expect(Notify.messages).to eq(
          export_report: [:email],
          stuck_pg_jobs: %i[email telegram]
        )

        expect(Notify.adapters).to eq(
          email: %i[export_report stuck_pg_jobs],
          telegram: [:stuck_pg_jobs]
        )
      end
    end
  end
end
