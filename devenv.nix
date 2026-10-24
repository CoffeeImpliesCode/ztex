{ pkgs, ... }:

rec {
  # The Zig launcher reads the version from build.zig.zon.
  packages = with pkgs; [
    bash
    pkg-config

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
