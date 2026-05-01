# typed: strict
# frozen_string_literal: true

require "json"

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
# Distribution split between three repos:
#   florentiu/lexis           PRIVATE  source code (this template lives here)
#   florentiu/lexis-releases  PUBLIC   binary mirror — only place URLs below resolve
#   florentiu/homebrew-lexis  PUBLIC   the rendered formula consumers tap into
# The mirror repo holds no source — just the per-arch tarballs uploaded
# by `release-lexis.yml`'s `github-release` job. That's why every URL
# below points at `lexis-releases`, not `lexis`.
#
# Tokens (used verbatim below, sed-replaced by the workflow):
#   0.4.5               — the engine version, e.g. 0.2.0
#   2bc1ba7112cdb5a6ba92ecf14c4166227df1cead8ac0f30c5acc65bb81807b48    — sha256 of the macOS arm64 tarball
#   76c29275c4244c0ad4f4f17b7cd4a55e59a14a609c4826e1b87adddb069b3b9d     — sha256 of the macOS x86_64 tarball
#   __SHA_AARCH64_LINUX__     — sha256 of the Linux arm64 tarball
#   298b989c8b3b839a45ca265e25b2e636f29c0607a7716eca76c4903125b2f7a3      — sha256 of the Linux x86_64 tarball
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
  # Source repo is private; this points at the public binary
  # distribution mirror so users have a landing page that actually
  # opens (the formula's `homepage` URL has to resolve or `brew
  # audit` flags it on tap CI).
  homepage "https://github.com/florentiu/lexis-releases"
  version "0.4.5"
  license :cannot_represent # source-available; see LICENSE

  # Per-arch binaries published as GitHub Release assets on the same
  # `lexis-v0.4.5` tag that built them. Keeping URL + sha256 inside
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
      url "https://github.com/florentiu/lexis-releases/releases/download/lexis-v0.4.5/lexis-0.4.5-aarch64-apple-darwin.tar.gz"
      sha256 "2bc1ba7112cdb5a6ba92ecf14c4166227df1cead8ac0f30c5acc65bb81807b48"
    end
    on_intel do
      url "https://github.com/florentiu/lexis-releases/releases/download/lexis-v0.4.5/lexis-0.4.5-x86_64-apple-darwin.tar.gz"
      sha256 "76c29275c4244c0ad4f4f17b7cd4a55e59a14a609c4826e1b87adddb069b3b9d"
    end
  end

  on_linux do
    # Linux arm64 binary temporarily unavailable while we resolve
    # cross-compile issues with `ort-sys`'s download-binaries build
    # script. Linux arm64 users can pull the multi-arch Docker image
    # (`docker pull ghcr.io/florentiu/lexis:0.4.5`) in the
    # meantime — that build path runs natively on an arm64 runner
    # and isn't affected. Re-add the block once the standalone arm64
    # tarball is back on the release.
    #
    # on_arm do
    #   url "https://github.com/florentiu/lexis-releases/releases/download/lexis-v0.4.5/lexis-0.4.5-aarch64-unknown-linux-gnu.tar.gz"
    #   sha256 "__SHA_AARCH64_LINUX__"
    # end
    on_intel do
      url "https://github.com/florentiu/lexis-releases/releases/download/lexis-v0.4.5/lexis-0.4.5-x86_64-unknown-linux-gnu.tar.gz"
      sha256 "298b989c8b3b839a45ca265e25b2e636f29c0607a7716eca76c4903125b2f7a3"
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

  # `post_install` runs on every `brew install lexis` AND every `brew
  # upgrade lexis`. We use it to auto-restart a daemon spawned by `lexis
  # serve --detach` (or by the `lexis init` wizard, which detaches the
  # same way) so an upgrade picks up the new binary instead of leaving
  # the previous version running in memory.
  #
  # Why this is needed: on Linux/macOS the kernel pins the in-memory
  # ELF/Mach-O mapping of a running process, so even after Homebrew
  # replaces `bin/lexis` with the new tarball, the in-flight engine
  # keeps executing the OLD code until something restarts it. Without
  # this hook, an operator who runs
  #
  #   lexis serve --detach --addr 0.0.0.0:5391    # on 0.2.2
  #   brew upgrade lexis                          # tarball drops 0.3.0
  #   lexis info                                  # still reports 0.2.2 — confusing
  #
  # would have to remember to `lexis stop && lexis serve --detach …`
  # by hand. Doing it here makes the upgrade transparent.
  #
  # Discovery contract: `lexis serve --detach` writes
  # `~/.lexis/serve.cmd` (a small JSON snapshot of `version`, `addr`,
  # `data_dir`) at spawn time, and `lexis stop` deletes it on a clean
  # stop. So the file's presence is the authoritative "there is a
  # detached daemon to restart" signal — present means restart, missing
  # means do nothing.
  #
  # Out of scope on purpose:
  #   - `brew services` users — launchd already restarts the daemon on
  #     binary change as part of `brew services restart`, and we don't
  #     want to double-spawn into a port collision. The cmd file isn't
  #     written by the launchd path so we naturally skip them.
  #   - systemd / nohup users — they manage the lifecycle out-of-band;
  #     the cmd file isn't written for those, so we leave them alone.
  #     The caveats section calls out the manual restart they need.
  #   - First-install case — no prior daemon to restart; the cmd file
  #     can't exist yet, so this block is a no-op on a fresh install.
  def post_install
    # Resolve `~/.lexis/` against the *invoking* user's home — Homebrew
    # runs `post_install` as the regular user (not root), so `Dir.home`
    # is correct. The state lives per-user, not under `var`, so we have
    # to leave the brew-managed prefix to find it.
    cmd_file = File.join(Dir.home, ".lexis", "serve.cmd")
    return unless File.exist?(cmd_file)

    cmd = begin
      JSON.parse(File.read(cmd_file))
    rescue JSON::ParserError, Errno::EACCES => e
      opoo "lexis: ~/.lexis/serve.cmd unreadable (#{e.message}); skipping daemon restart"
      return
    end

    addr = cmd["addr"].to_s
    if addr.empty?
      opoo "lexis: ~/.lexis/serve.cmd has no `addr` field; skipping daemon restart"
      return
    end

    # Stop the old engine, then spawn a new one. Both calls go through
    # the freshly-installed binary at `bin/"lexis"`, so the second call
    # writes a new `serve.cmd` stamped with the new version. We use
    # `system` (array form) — no shell, no injection surface — and
    # don't error-out on a non-zero exit: `lexis stop` returns 0 when
    # nothing is running ("nothing to stop"), and we want a missing
    # daemon to be a no-op rather than abort the upgrade.
    ohai "lexis: restarting detached engine on #{addr} with the new binary"
    system bin/"lexis", "stop"
    if system bin/"lexis", "serve", "--detach", "--addr", addr
      ohai "lexis: engine re-spawned on #{addr}"
    else
      opoo "lexis: failed to re-spawn engine on #{addr} — start it manually with: lexis serve --detach --addr #{addr}"
    end
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

      Background-mode lifecycle (`lexis init` / `lexis serve --detach`):
        Daemons spawned via the wizard or `--detach` write their state
        to ~/.lexis/serve.cmd. `brew upgrade lexis` reads that file and
        automatically restarts the engine on the new binary, so an
        upgrade is transparent.

        If you manage the engine through systemd, nohup, or a custom
        init script, that file isn't written and `brew upgrade` will
        leave your engine running on the old version. Restart it
        yourself after the upgrade:
          systemctl --user restart lexis    # systemd unit
          # or stop and re-spawn under your own supervisor
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
