# Home Manager service for llama.cpp's `llama-server`.
#
# Inspired by:
#   - nixpkgs NixOS module: nixos/modules/services/misc/llama-cpp.nix
#   - home-manager service:  modules/services/ollama.nix
#
# Runs llama-server as a per-user service: a systemd user service on Linux and
# a launchd agent on Darwin, just like the upstream ollama Home Manager module.
#
# Import it into a Home Manager configuration, e.g. via this NUR repo:
#   imports = [ nur.repos.congee.modules.llama-cpp ];
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkIf
    mkOption
    mkEnableOption
    mkPackageOption
    types
    literalExpression
    ;

  cfg = config.services.llama-cpp;

  # Effective package: apply the build-time acceleration flags of the nixpkgs
  # llama-cpp derivation, mirroring how the home-manager ollama module derives
  # its package from `cfg.acceleration`.
  llamaPackage =
    let
      overrides =
        lib.optionalAttrs (cfg.acceleration == false) {
          cudaSupport = false;
          rocmSupport = false;
          vulkanSupport = false;
        }
        // lib.optionalAttrs (cfg.acceleration == "cuda") {
          cudaSupport = true;
        }
        // lib.optionalAttrs (cfg.acceleration == "rocm") (
          { rocmSupport = true; }
          // lib.optionalAttrs (cfg.rocmGpuTargets != [ ]) { inherit (cfg) rocmGpuTargets; }
        )
        // lib.optionalAttrs (cfg.acceleration == "vulkan") {
          vulkanSupport = true;
        };
    in
    if overrides == { } then cfg.package else cfg.package.override overrides;

  modelsPresetFile =
    if cfg.modelsPreset != null then
      pkgs.writeText "llama-models.ini" (lib.generators.toINI { } cfg.modelsPreset)
    else
      null;

  # Mirrors the argument ordering used by the upstream NixOS module.
  args =
    [
      "--host"
      cfg.host
      "--port"
      (toString cfg.port)
    ]
    ++ lib.optionals (cfg.model != null) [
      "-m"
      cfg.model
    ]
    ++ lib.optionals (cfg.modelsDir != null) [
      "--models-dir"
      cfg.modelsDir
    ]
    ++ lib.optionals (cfg.modelsPreset != null) [
      "--models-preset"
      modelsPresetFile
    ]
    ++ cfg.extraFlags;

  # Full argv as plain strings (paths/ints coerced), reused by both backends.
  argv = map toString ([ (lib.getExe' llamaPackage "llama-server") ] ++ args);
in
{
  options.services.llama-cpp = {
    enable = mkEnableOption "llama.cpp server (llama-server) as a per-user service";

    package = mkPackageOption pkgs "llama-cpp" { };

    acceleration = mkOption {
      type = types.nullOr (types.enum [ false "rocm" "cuda" "vulkan" ]);
      default = null;
      example = "rocm";
      description = ''
        What interface to use for hardware acceleration. Selecting one rebuilds
        the {option}`services.llama-cpp.package` with the matching backend.

        - `null`: use the package as-is (honours `nixpkgs.config.cudaSupport`
          and `nixpkgs.config.rocmSupport`).
        - `false`: CPU only (disables CUDA, ROCm and Vulkan).
        - `"rocm"`: build the ROCm/HIP backend, for most modern AMD GPUs. If
          your card is not built by default you may also need to set
          {option}`services.llama-cpp.rocmGpuTargets`, and/or export
          `HSA_OVERRIDE_GFX_VERSION` via
          {option}`services.llama-cpp.environmentVariables`.
        - `"cuda"`: build the CUDA backend, for most modern NVIDIA GPUs.
        - `"vulkan"`: build the Vulkan backend. The practical choice for GPUs
          without current ROCm/CUDA support (e.g. older AMD cards such as
          Polaris/gfx803) and for cross-vendor setups.
      '';
    };

    rocmGpuTargets = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "gfx1100" ];
      description = ''
        AMD GPU targets to build the ROCm/HIP backend for (passed through to the
        llama-cpp package's `rocmGpuTargets` argument). Leave empty to use the
        package default. Only takes effect when
        {option}`services.llama-cpp.acceleration` is `"rocm"`. Discover your
        target with `rocminfo | grep gfx`.
      '';
    };

    model = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/models/mistral-instruct-7b/ggml-model-q4_0.gguf";
      description = "Path to a single model file to load (`-m`).";
    };

    modelsDir = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/models/";
      description = "Models directory (`--models-dir`).";
    };

    modelsPreset = mkOption {
      type = types.nullOr (types.attrsOf types.attrs);
      default = null;
      description = ''
        Models preset configuration as a Nix attribute set. This is converted to
        an INI file and passed to llama-server via `--models-preset`. See the
        llama-server documentation for available options.
      '';
      example = literalExpression ''
        {
          "Qwen3-Coder-Next" = {
            hf-repo = "unsloth/Qwen3-Coder-Next-GGUF";
            hf-file = "Qwen3-Coder-Next-UD-Q4_K_XL.gguf";
            alias = "unsloth/Qwen3-Coder-Next";
            fit = "on";
            jinja = "on";
          };
        }
      '';
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      example = "0.0.0.0";
      description = "IP address the llama.cpp server listens on.";
    };

    port = mkOption {
      type = types.port;
      default = 11434;
      description = "Listen port for the llama.cpp server.";
    };

    extraFlags = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "-c"
        "4096"
        "-ngl"
        "32"
      ];
      description = "Extra flags passed to llama-server.";
    };

    environmentVariables = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        LLAMA_CACHE = "/home/alice/.cache/llama.cpp";
      };
      description = ''
        Extra environment variables for the llama-server service. Useful for
        things like `LLAMA_CACHE` (download cache for `hf-repo` models) or GPU
        device selection (`CUDA_VISIBLE_DEVICES`, `HIP_VISIBLE_DEVICES`).
      '';
    };
  };

  config = mkIf cfg.enable {
    # Linux: systemd user service.
    systemd.user.services.llama-cpp = {
      Unit = {
        Description = "llama.cpp server";
        After = [ "network.target" ];
      };

      Service = {
        ExecStart = lib.escapeShellArgs argv;
        Environment = lib.mapAttrsToList (n: v: "${n}=${v}") cfg.environmentVariables;
        Restart = "on-failure";
        RestartSec = 3;
      };

      Install.WantedBy = [ "default.target" ];
    };

    # Darwin: launchd agent.
    launchd.agents.llama-cpp = {
      enable = true;
      config = {
        ProgramArguments = argv;
        EnvironmentVariables = cfg.environmentVariables;
        KeepAlive = {
          Crashed = true;
          SuccessfulExit = false;
        };
        ProcessType = "Background";
      };
    };
  };
}
