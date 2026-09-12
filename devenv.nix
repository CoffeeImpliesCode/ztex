{ pkgs, ... }:

rec {
  # zig 0.16 dev environment (house convention, cf. ~/projects/wayland).
  # https://devenv.sh/basics/
  packages = with pkgs; [
    zig                # the toolchain: zig 0.16
    bash
    pkg-config

    # Gate analyzers that are not in nixpkgs live in ~/tools and are exposed
    # through ~/.local/bin: zwanzig (required by scripts/gate.sh), zlint,
    # ziglint, zbc, zig-cov. See AGENTS.md.

    # performance / profiling tooling (ztex: speed is a top priority)
    hyperfine        # CLI timing of benchmarks
    valgrind         # memory / cachegrind analysis
    perf-tools       # linux perf profiler

    # math fonts so rendered SVGs resolve to Computer Modern shapes
    lmmath           # Latin Modern Math
    lmodern          # Latin Modern Roman
  ];

  env = {
    LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath packages}";
    INCLUDE_DIRECTORIES = "${pkgs.lib.makeIncludePath packages}";
  };

  # https://devenv.sh/languages/
  # languages.zig.enable = true;

  scripts.gate.exec = "bash scripts/gate.sh";
}
