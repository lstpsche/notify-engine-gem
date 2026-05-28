# notify-engine

`notify-engine` is a Rails engine gem for convention-over-configuration notification dispatch. The long-term design is filesystem-routed, multi-channel delivery from `app/notify_templates`, with payload classes and pluggable adapters.

This repository is currently at **Phase 1**: registry and template discovery.

## Current Status

Implemented:

- `Notify::VERSION`
- `Notify.config`, `Notify.configure`, `Notify.reset_config!`
- `Notify.register_adapter`, `Notify.registered_adapters`, `Notify.reset_adapters!`
- `Notify::Config`
- `Notify::Engine`
- Custom errors under `Notify`
- `Notify::Registry` — filesystem-driven template scanner
- `Notify.messages` — `{ message_name: [:adapter1, :adapter2] }`
- `Notify.adapters` — `{ adapter: [:msg1, :msg2] }`
- `Notify.registry` — direct registry access
- Development reload via `to_prepare`; production freeze

Not implemented yet:

- `Notify.message` dispatch
- Payload classes
- Built-in email or Telegram adapters
- Test mode and test helpers
- Instrumentation
- Generators
- Full user guide

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

## Template Directory Convention

Place templates in `app/notify_templates/<adapter>/<message>.<format>.<handler>`:

```text
app/notify_templates/
├── email/
│   ├── stuck_pg_jobs.html.erb
│   ├── stuck_pg_jobs.text.erb     # multipart companion — same message
│   ├── export_report.html.erb
│   └── _disabled_message.html.erb # _ prefix = excluded from registry
├── telegram/
│   └── stuck_pg_jobs.md.erb
└── stuck_pg_jobs.rb               # optional PayloadClass (Phase 2)
```

- Each subdirectory of `app/notify_templates/` is an **adapter name**.
- Files within an adapter directory are **templates**. The base filename (without format and handler extensions) is the **message name**.
- Files starting with `_` are excluded from the registry.
- Multipart templates (`.html.erb` + `.text.erb`) are de-duplicated into a single message.
- Template discovery is **format-agnostic**: any handler registered via `ActionView::Template::Handlers` is supported (ERB, Haml, Slim, etc.).

### Introspection

```ruby
Notify.messages
# => { export_report: [:email], stuck_pg_jobs: [:email, :telegram] }

Notify.adapters
# => { email: [:export_report, :stuck_pg_jobs], telegram: [:stuck_pg_jobs] }
```

Both are sorted alphabetically at all levels.

## Configuration

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

Adapter classes can be registered for future dispatcher work. The gem does not deliver notifications yet.

```ruby
Notify.register_adapter(:custom, CustomAdapter)
Notify.registered_adapters
# => { custom: CustomAdapter }
```

String keys are normalized to symbols, and registering the same key again replaces the previous class.

## Rails Engine

`Notify::Engine` adds the configured template path to autoload and eager-load paths, builds the registry via `to_prepare` (rebuilt on each development reload, built once and frozen in production).

## Planned Next Phases

- Payload class DSL and resolution priority.
- Adapter interface and delivery dispatcher.
- Built-in email adapter and internal mailer.
- Test mode and assertion helpers.
- Generators and complete documentation.
