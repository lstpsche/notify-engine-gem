# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "notify-engine"
  spec.version = "0.1.0"
  spec.authors = ["Nikita Shkoda"]
  spec.email = ["lstpsche@gmail.com"]

  spec.summary = "Convention-over-configuration multi-channel notifications for Rails."
  spec.description = "Rails engine gem for filesystem-driven notification routing, adapter delivery, and optional payload computation."
  spec.homepage = "https://github.com/lstpsche/notify-engine-gem"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage
  }

  spec.files = Dir.chdir(__dir__) do
    Dir[
      ".rspec",
      "Gemfile",
      "LICENSE",
      "README.md",
      "Rakefile",
      "lib/**/*",
      "spec/**/*"
    ].select { |path| File.file?(path) }
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "actionmailer", ">= 7.0", "< 9.0"
  spec.add_dependency "actionview", ">= 7.0", "< 9.0"
  spec.add_dependency "activesupport", ">= 7.0", "< 9.0"
  spec.add_dependency "railties", ">= 7.0", "< 9.0"

  spec.add_development_dependency "rake", ">= 13.0", "< 15.0"
  spec.add_development_dependency "rspec", ">= 3.13", "< 4.0"
  spec.add_development_dependency "rspec-rails", ">= 7.0", "< 9.0"
end
