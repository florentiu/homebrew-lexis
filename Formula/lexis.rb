# typed: strict
# frozen_string_literal: true

# Homebrew formula for the Lexis search engine.
#
# This file is the source of truth — the published tap at
# `florentiu/homebrew-lexis` is a copy of `Formula/lexis.rb` from here.
# End-user install:
#
#   brew tap florentiu/lexis
#   brew install lexis --HEAD
#
# To iterate on this file before pushing to the tap, drop it into a
# one-off local tap (modern Homebrew refuses loose `.rb` paths):
#
#   brew tap-new --no-git florentiu/lexis-local
#   cp apps/lexis/homebrew/lexis.rb \
#      "$(brew --repository florentiu/lexis-local)/Formula/lexis.rb"
#   brew install --HEAD florentiu/lexis-local/lexis
#
# The formula builds from source via `cargo`. There is no bottle yet —
# add a `bottle do ... end` block once we wire a release pipeline that
# publishes per-arch binaries to GitHub releases. Until then, install
# takes a few minutes the first time (mostly Tantivy + RocksDB).

# Lexis: embedded search engine — Tantivy index + admin/search HTTP API.
class Lexis < Formula
  desc "Embedded search engine — Tantivy index + admin/search HTTP API"
  homepage "https://github.com/florentiu/lexis"
  license :cannot_represent # source-available; see LICENSE
  head "https://github.com/florentiu/lexis.git", branch: "main"

  # Once a tagged release exists, drop the `head_only` constraint by
  # adding a stable `url` + `sha256` block here, e.g.
  #
  #   url "https://github.com/florentiu/lexis/archive/refs/tags/v0.1.0.tar.gz"
  #   sha256 "<sha256 of the tarball>"
  #
  # Until then, only `brew install --HEAD lexis` is supported.

  depends_on "rust" => :build

  uses_from_macos "curl" => :test

  def install
    # `cargo install` against the workspace member's manifest. `std_cargo_args`
    # expands to `--locked --root <prefix> --path <path>` so the binary lands
    # in `prefix/bin/lexis` automatically. Pointing at the crate path (not a
    # `--package` flag) is the Homebrew-blessed way to build a workspace
    # member; the audit rule (FormulaAudit/Text) flags `cargo build` directly.
    system "cargo", "install", *std_cargo_args(path: "crates/lexis-cli")

    # Pre-create the runtime data dir. Two reasons we have to do this in
    # `install` rather than relying on the engine to mkdir at startup:
    #   - launchd (`brew services`) refuses to spawn the process if the
    #     plist's `WorkingDirectory` doesn't exist — exits with 78 before
    #     the binary ever runs.
    #   - The engine writes its index/license/state under `--data-dir`, so
    #     having the parent ready avoids a race the first time the user
    #     hits an admin endpoint.
    (var/"lexis").mkpath
  end

  # Per-user launchd service. `brew services start lexis` writes the
  # plist into ~/Library/LaunchAgents and load-loads it; `stop` removes
  # it. Logs go to a single file (the engine writes via `tracing` to
  # stderr).
  service do
    run [
      opt_bin/"lexis",
      "--data-dir", var/"lexis",
      "serve",
      "--addr", "127.0.0.1:5391"
    ]
    keep_alive true
    working_dir var/"lexis"
    log_path var/"log/lexis.log"
    error_log_path var/"log/lexis.log"
    environment_variables RUST_LOG: "info"
  end

  def caveats
    <<~EOS
      Lexis is configured as a per-user launchd service.

        brew services start lexis     # auto-start on login
        brew services run   lexis     # one-shot, no auto-start
        brew services stop  lexis     # stop and unload

      Defaults:
        Listen address   127.0.0.1:5391
        Data directory   #{var}/lexis
        Log file         #{var}/log/lexis.log

      The admin API is unauthenticated — keep the listener on 127.0.0.1
      unless you put a reverse-proxy with auth in front of it.

      Pair with Lexis Web (the dashboard):
        - Docker dashboard → connection URL: http://host.docker.internal:5391
        - Native dashboard → connection URL: http://127.0.0.1:5391

      One-shot foreground run (handy for debugging):
        lexis --data-dir #{var}/lexis serve --addr 127.0.0.1:5391
    EOS
  end

  test do
    # Version smoke test — fails fast if the binary is broken.
    assert_match version.to_s, shell_output("#{bin}/lexis --version")

    # End-to-end: spin the server up against an empty data dir, hit
    # `/health`, then `/v1/info` to confirm it's actually a Lexis engine
    # (not a generic 200-returning process). `free_port` is a Homebrew
    # test helper that grabs an unused port atomically.
    port = free_port
    data = testpath/"data"
    data.mkpath

    pid = spawn bin/"lexis", "--data-dir", data,
                "serve", "--addr", "127.0.0.1:#{port}"
    sleep 4

    begin
      health = shell_output("/usr/bin/curl -fsS http://127.0.0.1:#{port}/health")
      assert_match(/"status":"ok"/, health)
      info = shell_output("/usr/bin/curl -fsS http://127.0.0.1:#{port}/v1/info")
      assert_match(/"instance_id":"[0-9a-f-]+"/, info)
    ensure
      Process.kill("TERM", pid)
      Process.wait(pid)
    end
  end
end
