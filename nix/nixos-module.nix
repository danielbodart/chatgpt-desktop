self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.chatgpt-desktop;
in
{
  options.programs.chatgpt-desktop = {
    enable = lib.mkEnableOption "ChatGPT Desktop";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.chatgpt-desktop;
      defaultText = lib.literalMD "`chatgpt-desktop` from this flake";
      description = "The chatgpt-desktop package to install.";
    };

    primaryRuntime.enable = lib.mkEnableOption ''
      the system side of the app's document tools. On first launch the app
      downloads a runtime into ~/.cache/codex-runtimes -- Node, Python,
      poppler and a headless LibreOffice -- behind its document, PDF,
      spreadsheet and presentation features. It is built for generic Linux,
      so it can only start through nix-ld. The package supplies the extra
      libraries LibreOffice needs; this turns nix-ld itself on
    '';
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        environment.systemPackages = [ cfg.package ];

        # The app keeps its session in the Secret Service keyring.
        services.gnome.gnome-keyring.enable = lib.mkDefault true;
      }

      (lib.mkIf cfg.primaryRuntime.enable {
        programs.nix-ld.enable = true;
      })
    ]
  );
}
