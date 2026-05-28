# notify-engine

`notify-engine` is a Rails engine gem for convention-over-configuration notification dispatch. The long-term design is filesystem-routed, multi-channel delivery from `app/notify_templates`, with payload classes and pluggable adapters.

This repository is currently at Phase 0: gem foundation and configuration contract.

## Phase 0 Status

Implemented:

- `Notify::VERSION`
- `Notify.config`
- `Notify.configure`
- `Notify.reset_config!`
- `Notify.register_adapter`
- `Notify.registered_adapters`
- `Notify.reset_adapters!`
- `Notify::Config`
- `Notify::Engine`
- custom errors under `Notify`

Not implemented yet:

- `Notify.message`
- filesystem registry scanning
- payload classes
- built-in email or Telegram adapters
- test mode and test helpers
- instrumentation
- generators
- full user guide

## Installation

Add the gem to a Rails application's Gemfile:

```ruby
gem "notify-engine"
```

For local development against this repository:

```sh
bundle install
bundle exec rspec
bundle exec rake
gem build notify-engine.gemspec
```

## Configuration

Phase 0 exposes a mutable configuration object. Runtime dispatch does not exist yet, but these keys are the foundation for later phases.

```ruby
Notify.configure do |config|
  config.templates_path = "app/notify_templates"

  config.adapters[:email] = {
    enabled: true,
    from: nil,
    delivery_method: :deliver_later,
    default_recipients: [],
    layout: false,
    helpers: [],
    subject_prefix: nil
  }

  config.adapters[:telegram] = {
    enabled: false,
    bots: []
  }

  config.messages[:stuck_pg_jobs] = {
    subject: "Stuck PgJobs detected"
  }
end
```

`Notify.reset_config!` restores clean defaults, including nested arrays and hashes.

## Adapter Registration

Phase 0 can record adapter classes for future dispatcher work. It does not deliver notifications.

```ruby
class CustomAdapter
end

Notify.register_adapter(:custom, CustomAdapter)
Notify.registered_adapters
# => { custom: CustomAdapter }
```

String keys are normalized to symbols, and registering the same key again replaces the previous class.

## Rails Engine

`Notify::Engine` adds the configured notify template path to the host application's autoload and eager-load paths. By default, that path is:

```text
app/notify_templates
```

The engine does not scan templates, constantize payload classes, register routes, or install generators in Phase 0.

## Planned Next Phases

- Registry and filesystem discovery.
- Payload class DSL and resolution priority.
- Adapter interface and delivery dispatcher.
- Built-in email adapter and internal mailer.
- Test mode and assertion helpers.
- Generators and complete documentation.
