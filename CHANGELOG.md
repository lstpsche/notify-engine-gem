# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-10-23

### Added

- Explicit single-channel `Notify.deliver` with required recipients, native JSON-safe locals, typed results and sanitized failure dispositions, preserving existing `Notify.message` behavior.
- `Notify.prepare` renders and validates without provider I/O, returning a process-local callable so callers can persist a pre-send checkpoint before delivery.
- Telegram adapter with named bots, plain-text templates, explicit chat destinations, bounded verified HTTPS requests, provider rate-delay metadata and safe access/permission errors.
- Per-message email Message-ID and SMTP timeout options; synchronous, queued, captured and suppressed outcomes remain distinct.
- Strict email delivery telemetry filters recipient and message fields. Capture mode retains explicit targets without claiming provider acceptance.
- Strict mail guards validate destinations and transport after interceptors; failures known to precede transport expose `attempted: false`. SMTP cleanup preserves the original transmission outcome.

## [0.1.1] - 2026-05-29

### Fixed

- Evaluate Procs/Lambdas stored in per-message config (`config.messages[:name]`) and adapter defaults (`config.adapters[:email]`) at dispatch time — previously returned as raw Proc objects for `email_recipients`, `subject`, `email_from`, `email_cc`, `email_bcc`, and `delivery_method`, breaking the documented config pattern

## [0.1.0] - 2026-05-29

### Added

- Convention-over-configuration message dispatch via `Notify.message(:name, **payload)` with `Notify.configure` block for adapter and per-message configuration
- Filesystem-driven template discovery at `app/notify_templates/<adapter>/<name>.<ext>` with format-agnostic scanning (ERB, Haml, Slim — any registered `ActionView` handler), `_` prefix to disable templates, and `Notify.messages` / `Notify.adapters` introspection
- Optional payload class compute layer (`Notify::PayloadClass`) with 7-method class-level DSL (`subject`, `email_recipients`, `email_from`, `email_cc`, `email_bcc`, `tg_recipients`, `locals`), static/Proc/block support via `instance_exec`, instance method overrides, and 5-level resolution priority chain
- ActionMailer-backed email adapter (`Notify::Adapters::Email`) with multipart support, configurable layout and helpers, subject prefix (String or Proc), CC/BCC, per-message from override, and delivery method selection (`deliver_later` default, `deliver_now` override)
- Test mode with `Notify.test_mode!`, `Notify.deliveries` capture array, and `Notify::TestHelper` providing `assert_notify_dispatched`, `last_notify_delivery`, and `setup_notify_test_mode` — auto-activates in `Rails.env.test?`
- `ActiveSupport::Notifications` instrumentation events: `notify.message.dispatch`, `notify.adapter.deliver`, `notify.adapter.error`
- Structured error handling: `Notify::UnknownMessage`, `Notify::MissingRecipients`, `Notify::MissingSubject`, and `Notify::DeliveryError` with aggregated `.adapter_errors` — per-adapter error isolation ensures one failure does not block other adapters
- Pluggable adapter system via `Notify.register_adapter(:name, klass)` and `Notify::Adapters::Base` contract (`#deliver`, `.template_extensions`) for custom delivery channels

[0.2.0]: https://github.com/lstpsche/notify-engine-gem/releases/tag/v0.2.0
[0.1.1]: https://github.com/lstpsche/notify-engine-gem/releases/tag/v0.1.1
[0.1.0]: https://github.com/lstpsche/notify-engine-gem/releases/tag/v0.1.0
