# notify-engine

Convention-over-configuration multi-channel notification dispatch for Rails.

- Conventional dispatch: `Notify.message(:name, **payload)`; explicit delivery outcomes: `Notify.deliver(:name, via:, to:, ...)`
- Filesystem-driven adapter routing — presence of a template determines which channels fire
- Optional payload class compute layer for recipient resolution, subject building, and data transformation
- Pluggable adapters (email and Telegram built-in, custom adapters via `Notify.register_adapter`)
- Introspection: `Notify.messages` and `Notify.adapters`

## Installation

Add the gem to your Rails application's Gemfile:

```ruby
gem "notify-engine"
```

Then run:

```sh
bundle install
```

**Requires Rails 7.0+.**

## Quick Start

**1. Create a template**

```text
app/notify_templates/email/stuck_pg_jobs.html.erb
```

```erb
<h2>Stuck PgJobs Detected</h2>

<p>The following jobs are stuck:</p>

<ul>
  <% @pg_jobs.each do |job| %>
    <li>Job #<%= job.id %> — stuck since <%= job.updated_at %></li>
  <% end %>
</ul>
```

**2. Configure the message**

```ruby
# config/initializers/notify.rb
Notify.configure do |config|
  config.adapters[:email] = {
    enabled: true,
    from: "alerts@example.com",
    delivery_method: :deliver_later
  }

  config.messages[:stuck_pg_jobs] = {
    subject: "Stuck PgJobs detected",
    email_recipients: -> { ENV.fetch("ADMIN_EMAILS", "").split(",") }
  }
end
```

**3. Dispatch**

```ruby
Notify.message(:stuck_pg_jobs, pg_jobs: stuck_jobs)
```

That's it. The email adapter picks up the template, resolves recipients and subject from config, and delivers.

## Template Directory Convention

```text
app/notify_templates/
├── email/
│   ├── stuck_pg_jobs.html.erb
│   ├── stuck_pg_jobs.text.erb      # multipart companion
│   ├── export_report.html.erb
│   └── _disabled_message.html.erb  # _ prefix = excluded from registry
├── telegram/
│   └── stuck_pg_jobs.text.erb
├── stuck_pg_jobs.rb                # optional PayloadClass
└── export_report.rb                # optional PayloadClass
```

- Each subdirectory of `app/notify_templates/` is an **adapter name**.
- Files within an adapter directory are **templates**. The base filename (without format and handler extensions) is the **message name**.
- Files starting with `_` are excluded from the registry (disabled).
- Multipart templates (`.html.erb` + `.text.erb`) are de-duplicated into a single message and produce a multipart email automatically.
- Template discovery is **format-agnostic**: any handler registered via `ActionView::Template::Handlers` is supported (ERB, Haml, Slim, etc.).
- Payload class files live alongside adapter directories, not inside them.

### Introspection

```ruby
Notify.messages
# => { export_report: [:email], stuck_pg_jobs: [:email, :telegram] }

Notify.adapters
# => { email: [:export_report, :stuck_pg_jobs], telegram: [:stuck_pg_jobs] }
```

Both hashes are sorted alphabetically at all levels. For advanced use, `Notify.registry` provides direct access to the underlying `Notify::Registry` instance.

## Configuration

```ruby
# config/initializers/notify.rb
Notify.configure do |config|
  # Where templates live (relative to Rails.root)
  config.templates_path = "app/notify_templates" # default

  # Email adapter settings
  config.adapters[:email] = {
    enabled: true,                                    # default: true
    from: "ae@novus.online",                          # default: nil (falls back to ActionMailer default)
    delivery_method: :deliver_later,                  # default: :deliver_later
    default_recipients: ["admin@example.com"],        # default: []
    layout: false,                                    # default: false (or a layout name string)
    helpers: [],                                      # default: [] (e.g. [MailerHelper])
    subject_prefix: -> { "[#{Rails.env.upcase}]:" }   # default: nil (String or Proc)
  }

  # Telegram adapter (disabled until explicitly configured)
  config.adapters[:telegram] = {
    enabled: false,
    bots: []
  }

  # Per-message overrides (optional — only when you don't use a payload class)
  config.messages[:stuck_pg_jobs] = {
    subject: "Stuck PgJobs detected",
    email_recipients: -> { ENV.fetch("AE_ADMINS_EMAILS", "").split(",") }
  }

  config.messages[:export_report] = {
    subject: "ThinkTime export report",
    email_recipients: -> { ENV.fetch("THINKTIME_ADMIN_EMAIL", "").split(",") }
  }
end
```

## Dispatching Messages

### Bare minimum — everything from config + template

```ruby
Notify.message(:stuck_pg_jobs, pg_jobs: stuck_jobs)
```

### Inline override of config defaults

```ruby
Notify.message(:stuck_pg_jobs,
  pg_jobs: stuck_jobs,
  subject: "Custom subject override",
  email_to: ["override@example.com"]
)
```

### Payload class handles everything

```ruby
Notify.message(:export_report, export_result: result)
```

### Reserved payload keys

These keys control dispatch behavior and are stripped from template locals:

| Key | Controls |
|-----|----------|
| `subject:` | Email subject line |
| `email_to:` | Email recipients override |
| `email_from:` | From address override |
| `email_cc:` | CC recipients |
| `email_bcc:` | BCC recipients |
| `tg_bots:` | Telegram bot targets |
| `delivery_method:` | `:deliver_later` or `:deliver_now` |

## Payload Classes

### Location and naming

Payload classes live at `app/notify_templates/<name>.rb` with the class name `NotifyTemplates::<CamelizedName>` inheriting from `Notify::PayloadClass`.

```text
app/notify_templates/stuck_pg_jobs.rb → NotifyTemplates::StuckPgJobs
app/notify_templates/export_report.rb → NotifyTemplates::ExportReport
```

### Full example

```ruby
# app/notify_templates/stuck_pg_jobs.rb
class NotifyTemplates::StuckPgJobs < Notify::PayloadClass
  subject { "#{@pg_jobs.size} stuck PgJob(s) detected" }
  email_recipients -> { ENV.fetch("AE_ADMINS_EMAILS", "").split(",") }
  email_cc ["manager@example.com"]
  tg_recipients %i[alerts_bot notifier]
  locals { { pg_jobs: @pg_jobs, detected_at: Time.current } }

  def initialize(**payload)
    @pg_jobs = payload[:pg_jobs]
  end
end
```

### DSL method semantics

Each DSL method accepts a static value, a Proc/Lambda, or a block:

```ruby
subject "Static subject"                           # static value
subject -> { "Dynamic: #{@pg_jobs.size} stuck" }   # Proc — instance_exec'd at dispatch
subject { "Dynamic: #{@pg_jobs.size} stuck" }      # block — instance_exec'd at dispatch
```

Blocks and Procs are `instance_exec`'d on the payload class instance at dispatch time (not at class load), so they have access to instance variables set in `initialize`.

### Instance method override

Define an instance method with the same name to take absolute precedence over the DSL declaration:

```ruby
class NotifyTemplates::StuckPgJobs < Notify::PayloadClass
  subject { "#{@pg_jobs.size} stuck PgJob(s)" }

  def initialize(**payload)
    @pg_jobs = payload[:pg_jobs]
  end

  def subject
    prefix = @pg_jobs.size > 10 ? "URGENT" : "Warning"
    "#{prefix}: #{@pg_jobs.size} stuck PgJob(s)"
  end
end
```

### Available DSL methods

| Method | Description |
|--------|-------------|
| `subject` | Email subject line |
| `email_recipients` | To: addresses (coerced to array) |
| `email_from` | From: address override |
| `email_cc` | CC: addresses |
| `email_bcc` | BCC: addresses |
| `tg_recipients` | Telegram bot name(s) |
| `locals` | Template variables hash |

### Resolution priority

When resolving `subject`, `recipients`, and `locals`, the first non-nil value wins:

1. **Payload class instance method** — runtime logic
2. **Payload class DSL declaration** — `instance_exec`'d at dispatch
3. **Inline kwargs** in `Notify.message()` call
4. **Per-message config** in initializer
5. **Global adapter defaults** in initializer

### When no payload class exists

- `locals` = raw `**payload` minus reserved keys
- Recipients and subject come from inline kwargs or initializer config
- If neither provides recipients → raises `Notify::MissingRecipients`
- If neither provides a subject (email) → raises `Notify::MissingSubject`

## Email Adapter

### Template rendering

Templates at `app/notify_templates/email/<name>.<format>.<handler>` are rendered by an internal ActionMailer subclass. Template locals are set as instance variables (`@var`) on the mailer, following ActionMailer convention.

### Multipart emails

If both `.html.erb` and `.text.erb` exist for the same message, ActionMailer automatically produces a multipart email.

### Subject prefix

`config.adapters[:email][:subject_prefix]` accepts a String or Proc, prepended to all email subjects:

```ruby
config.adapters[:email][:subject_prefix] = -> { "[#{Rails.env.upcase}]:" }
# Subject "Stuck PgJobs" becomes "[PRODUCTION]: Stuck PgJobs"
```

When `nil` or empty, no prefix is applied.

### Layout

`config.adapters[:email][:layout]` defaults to `false` (no layout). Set to a layout name string to wrap templates in a layout from `app/views/layouts/`:

```ruby
config.adapters[:email][:layout] = "notify_mailer"
```

### Helpers

`config.adapters[:email][:helpers]` — array of helper modules available in templates:

```ruby
config.adapters[:email][:helpers] = [MailerHelper]
```

### CC/BCC

Set via payload class DSL (`email_cc`, `email_bcc`), per-message config, or inline kwargs:

```ruby
Notify.message(:stuck_pg_jobs, pg_jobs: jobs, email_cc: ["manager@example.com"])
```

### From override

Resolution: payload class `email_from` → per-message config → adapter config `from:` → ActionMailer default.

### Delivery method

Defaults to `:deliver_later`. Override per-adapter, per-message, or inline:

```ruby
# Per-message config
config.messages[:stuck_pg_jobs] = {
  subject: "Stuck PgJobs",
  email_recipients: ["admin@example.com"],
  delivery_method: :deliver_now
}

# Inline
Notify.message(:stuck_pg_jobs, pg_jobs: jobs, delivery_method: :deliver_now)
```

### Recipient arrayification

All recipient values are coerced to arrays — passing a single string works fine.

## Test Mode

### Activation

Test mode auto-activates in `Rails.env.test?` via an engine initializer. For manual activation:

```ruby
Notify.test_mode!
```

Check status with `Notify.test_mode?`. Deactivate with `Notify.reset_test_mode!`.

### Captured deliveries

When test mode is active, `Notify.message` captures dispatches to `Notify.deliveries` instead of delivering. Each entry is a hash:

```ruby
{
  name: :stuck_pg_jobs,
  adapters: [:email],
  payload: { pg_jobs: [...] },
  resolved: {
    subject: "3 stuck PgJob(s) detected",
    recipients: { email: ["admin@example.com"] },
    locals: { pg_jobs: [...] }
  }
}
```

The `recipients` hash is keyed by adapter symbol because recipient formats differ across adapters.

### RSpec setup

```ruby
# spec/support/notify.rb (or spec/rails_helper.rb)
RSpec.configure do |config|
  config.include Notify::TestHelper
  config.before(:each) { Notify.deliveries.clear }
end
```

### Assertion methods

| Method | Description |
|--------|-------------|
| `assert_notify_dispatched(:name, count:, to:)` | Verify a message was dispatched (optionally check count and recipients) |
| `last_notify_delivery` | Shorthand for `Notify.deliveries.last` |
| `setup_notify_test_mode` | Activate test mode and clear deliveries |

### Full test example

```ruby
RSpec.describe "Stuck PgJobs notification" do
  it "dispatches to admin emails" do
    Notify.message(:stuck_pg_jobs, pg_jobs: [double(id: 1, updated_at: Time.current)])

    assert_notify_dispatched(:stuck_pg_jobs, count: 1)
    assert_notify_dispatched(:stuck_pg_jobs, to: ["admin@example.com"])

    delivery = last_notify_delivery
    expect(delivery[:resolved][:subject]).to include("stuck")
    expect(delivery[:resolved][:locals][:pg_jobs]).to be_present
  end
end
```

## Instrumentation

The dispatcher emits `ActiveSupport::Notifications` events:

| Event | Payload | When |
|-------|---------|------|
| `notify.message.dispatch` | `{ message_name:, adapters: }` | On dispatch entry |
| `notify.adapter.deliver` | `{ message_name:, adapter:, to: }` | Per-adapter delivery |
| `notify.adapter.error` | `{ message_name:, adapter:, error: }` | On adapter failure |

### Subscriber example

```ruby
ActiveSupport::Notifications.subscribe("notify.message.dispatch") do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  Rails.logger.info(
    "[Notify] Dispatched #{event.payload[:message_name]} to #{event.payload[:adapters]}"
  )
end
```

## Custom Adapters

### Adapter contract

Custom adapters inherit from `Notify::Adapters::Base` and implement two methods:

```ruby
class MySlackAdapter < Notify::Adapters::Base
  def deliver(message_name:, to:, subject:, locals:, template_path:, options: {})
    # Deliver the notification via your channel.
    # `to` is the resolved recipients array.
    # `locals` is the resolved template variables hash.
    # `template_path` is the Pathname to the adapter's template directory.
  end

  def self.template_extensions
    # Return an array of file extensions this adapter recognizes.
    # Used by the registry to discover templates.
    %i[text.erb md.erb]
  end
end
```

### Registration

```ruby
# config/initializers/notify.rb
Notify.register_adapter(:slack, MySlackAdapter)
```

Once registered, drop templates in `app/notify_templates/slack/` and they auto-route on dispatch.

## Error Handling

| Error | Raised when |
|-------|-------------|
| `Notify::UnknownMessage` | `Notify.message(:nonexistent)` — no templates found for this name |
| `Notify::MissingRecipients` | No recipients resolvable for an adapter |
| `Notify::MissingSubject` | No subject resolvable for the email adapter |
| `Notify::DeliveryError` | ALL adapters fail (access individual errors via `.adapter_errors`) |

### Adapter error isolation

When multiple adapters handle a message, one adapter failing does not block the others. Only if **all** adapters fail does `Notify::DeliveryError` propagate to the caller.

### Payload class initialization errors

If a payload class raises during `initialize` or any resolution method, the error is caught and logged. The dispatcher falls back to raw payload mode for that adapter.

## Out of Scope

The following are outside the gem's scope:

- Delivery tracking / persistence
- User preferences / opt-out
- Template previews (à la `ActionMailer::Preview`)
- Retry logic (delegated to ActiveJob/Sidekiq via `deliver_later`)
- Admin UI
- I18n locale switching
- Attachments
- Rate limiting / deduplication
- Migration tooling (manual conversion required)
- Rails generators (`rails g notify:template`)

## Development

```sh
git clone https://github.com/lstpsche/notify-engine-gem.git
cd notify-engine-gem
bundle install
```

Run tests:

```sh
bundle exec rspec
```

Build the gem:

```sh
gem build notify-engine.gemspec
```

## License

MIT — see [LICENSE](LICENSE).

## Explicit delivery outcomes

Use `Notify.deliver` when the caller must identify one exact destination and know what happened. It does not consult payload-class recipients, default recipients, CC/BCC overrides or per-message subject defaults. Email still uses the configured sender, layout, helpers and subject prefix.

```ruby
result = Notify.deliver(:alert,
  via: :email,
  to: "operator@example.com",
  subject: "Document needs attention",
  locals: { body: "Review the document in the application." },
  delivery_method: :deliver_now,
  message_id: "stable-document-notice@example.com",
  delivery_options: { open_timeout: 5, read_timeout: 15 })

result.adapter     # :email
result.status      # :accepted, :enqueued or :captured
result.provider_id # optional String
```

`accepted` means the provider accepted the write. `enqueued` means only that ActionMailer accepted an asynchronous job. `captured` means test capture or a local test/file transport. Suppressed delivery and missing/disabled adapters are explicit failures. Acceptance does not prove inbox placement, human visibility or reading.

Failures raise `Notify::DeliveryFailure` with a safe `code`, `disposition` (`permanent`, `retryable` or `uncertain`), and optional `http_status`, `provider_error_code`, and `retry_after`. `attempted == false` explicitly identifies a failure known to precede transport execution; nil leaves that unspecified. No automatic retries are performed. A timeout or lost response after transmission can be uncertain and must not be blindly retried. Strict errors emit `notify.adapter.error` once; transport invocations emit `notify.adapter.deliver` without recipient/content fields. Callers own persistence, retry policy, rate coordination and reconciliation.

Strict email checks its recipient, envelope destination and transport again after Mail interceptors run. Interceptors may suppress delivery, but redirecting it, adding recipients or substituting an unsupported transport fails before provider I/O. SMTP session cleanup cannot replace the original transmission failure or undo known acceptance.

For a durable sender, prepare before recording the send boundary:

```ruby
prepared = Notify.prepare(:alert, via: :email, to: "operator@example.com",
  subject: "Document needs attention", locals: { body: "Review required." })
# Persist the application's pre-send checkpoint here.
result = prepared.call
# Persist acceptance outside the provider-error rescue boundary.
```

Preparation renders/validates without opening a provider connection. The callable is process-local: do not serialize or enqueue it. Calling it again performs another invocation; idempotency belongs to the caller. Use native JSON-safe locals so `deliver_later` remains serializable. Custom legacy adapters need not implement the strict API.

## Telegram

Configure named bot entries. Tokens can be callables and are evaluated when preparing a message:

```ruby
Notify.configure do |config|
  config.adapters[:telegram] = {
    enabled: true,
    bots: [{ name: :alerts, token: -> { ENV.fetch("ALERT_BOT_TOKEN") }, enabled: true }],
    open_timeout: 5, read_timeout: 15, write_timeout: 15
  }
end
```

Create `app/notify_templates/telegram/alert.text.erb`, using ordinary template locals:

```erb
<%= text -%>
```

```ruby
Notify.deliver(:alert, via: :telegram,
  to: { bot: :alerts, chat_id: "@alerts_channel" },
  locals: { text: "Document needs attention." })
```

Telegram is synchronous and uses plain text, with no parse mode or link previews. Messages must fit the Bot API's 4096-character limit; the adapter rejects oversized input instead of splitting it. Bot and chat must be explicit for strict sends. Public channel/supergroup handles and numeric chat IDs are supported; personal usernames are not direct-message destinations. Channel owners must add the bot and grant posting rights. Personal recipients must first start/message the bot and then be addressed by numeric chat ID.

Legacy `Notify.message(:alert, tg_bots: [:alerts], text: "...")` can select configured bot names when each has an explicit default `chat_id` in its bot entry. A disabled bot is skipped only in legacy dispatch; unknown names are errors. Strict sends never fall back to a bot's default chat.

Telegram failures expose stable safe reasons including unavailable chat, missing membership/posting rights, blocking, invalid credentials and rate limits. Unknown provider descriptions remain generic rejections. A migrated chat ID requires configuration correction and is never silently substituted. Raw provider descriptions and credential-bearing exceptions are not retained. If the application instruments Net::HTTP, redact bot-token URL segments in its breadcrumb/transaction exporters too; the Telegram API puts the token in the request path.

`Notify.test_mode!` captures strict targets/locals in `Notify.deliveries` and returns `captured`. Disable that mode explicitly when testing actual transport behavior with a fake provider. No bot polling, inbound webhook, user-account login, database ledger or background retry engine is included.
