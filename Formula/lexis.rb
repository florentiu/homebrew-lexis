# typed: strict
# frozen_string_literal: true

# Homebrew formula TEMPLATE for the Lexis search engine.
#
# This file is the source of truth — the published tap at
# `florentiu/homebrew-lexis` is auto-updated by `.github/workflows/
# release-lexis.yml` whenever a tag of the form `lexis-v*.*.*` is pushed.
# The workflow substitutes five tokens below with the new version + the
# four per-arch tarball sha256 hashes, then commits the result as
# `Formula/lexis.rb` directly to the tap's `main` branch (no PR review
# — engine releases must propagate fast so users get `brew upgrade`
# access the moment a tag lands).
#
# Tokens (used verbatim below, sed-replaced by the workflow):
#   0.2.0               — the engine version, e.g. 0.2.0
#   f4dd5bd79787bee40d7850f6943394e59fc42ee95630aa027539b26e267143bd    — sha256 of the macOS arm64 tarball
#   fe99ff344995b34ec95fb92e6a2195fa159c2f26d916cee69f49f4a7ea8fdff8     — sha256 of the macOS x86_64 tarball
#   d06add63f18f338936be5a629ec46b257a72aea0ddee8251e07b303af9ffe91d     — sha256 of the Linux arm64 tarball
#   d394caada0e0f1088f6d713b8f4e5cc29d4989bcab3d46f6dc91a754b8ef4304      — sha256 of the Linux x86_64 tarball
#
# End-user install (after first `lexis-v*` tag has been published):
#
#   brew tap florentiu/lexis
#   brew install lexis
#   brew services start lexis
#
# No Rust toolchain on the user's machine, no source build — Homebrew
# just downloads the per-arch tarball matching the host and drops the
# `lexis` binary into `prefix/bin/`. `brew upgrade lexis` picks up new
# tags as the workflow re-stamps this file.
class Lexis < Formula
  desc "Embedded search engine — Tantivy index + admin/search HTTP API"
  homepage "https://github.com/florentiu/lexis"
  version "0.2.0"
  license :cannot_represent # source-available; see LICENSE

  # Per-arch binaries published as GitHub Release assets on the same
  # `lexis-v0.2.0` tag that built them. Keeping URL + sha256 inside
  # the matching `on_macos`/`on_linux` blocks lets a single formula
  # serve every supported (os, arch) combination — Homebrew picks the
  # right block based on `Hardware::CPU.arch` at install time.
  #
  # Tarball convention: `lexis-{version}-{rust-target-triple}.tar.gz`,
  # gzipped tarball containing a single bare binary at `./lexis` (no
  # nested top-level directory). `bin.install "lexis"` below relies on
  # exactly that layout — keep it stable across releases.
  on_macos do
    on_arm do
      url "https://github.com/florentiu/lexis/releases/download/lexis-v0.2.0/lexis-0.2.0-aarch64-apple-darwin.tar.gz"
      sha256 "f4dd5bd79787bee40d7850f6943394e59fc42ee95630aa027539b26e267143bd"
    end
    on_intel do
      url "https://github.com/florentiu/lexis/releases/download/lexis-v0.2.0/lexis-0.2.0-x86_64-apple-darwin.tar.gz"
      sha256 "fe99ff344995b34ec95fb92e6a2195fa159c2f26d916cee69f49f4a7ea8fdff8"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/florentiu/lexis/releases/download/lexis-v0.2.0/lexis-0.2.0-aarch64-unknown-linux-gnu.tar.gz"
      sha256 "d06add63f18f338936be5a629ec46b257a72aea0ddee8251e07b303af9ffe91d"
    end
    on_intel do
      url "https://github.com/florentiu/lexis/releases/download/lexis-v0.2.0/lexis-0.2.0-x86_64-unknown-linux-gnu.tar.gz"
      sha256 "d394caada0e0f1088f6d713b8f4e5cc29d4989bcab3d46f6dc91a754b8ef4304"
    end
  end

  uses_from_macos "curl" => :test

  def install
    # Tarball lays the binary down at the archive root, no nested
    # directory — `bin.install` copies it into `prefix/bin/lexis` and
    # marks it executable.
    bin.install "lexis"

    # Pre-create the runtime data dir. Two reasons we have to do this
    # at install time rather than relying on the engine to mkdir at
    # startup:
    #   - launchd (`brew services`) refuses to spawn the process if
    #     the plist's `WorkingDirectory` doesn't exist — exits with 78
    #     before the binary ever runs.
    #   - The engine writes its index/license/state under `--data-dir`,
    #     so having the parent ready avoids a race the first time the
    #     user hits an admin endpoint.
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

      The engine's management routes are unauthenticated — keep the
      listener on 127.0.0.1 unless you put a reverse-proxy with auth in
      front of it.

      Pair with Lexis Web (the dashboard):
        - Docker dashboard → connection URL: http://host.docker.internal:5391
        - Native dashboard → connection URL: http://127.0.0.1:5391

      One-shot foreground run (handy for debugging):
        lexis --data-dir #{var}/lexis serve --addr 127.0.0.1:5391
    EOS
  end

  test do
    # Version smoke test — fails fast if the binary is broken or the
    # workflow stamped the wrong `version` token.
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
