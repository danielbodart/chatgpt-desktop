# The four xdg-utils commands Electron runs, reimplemented on GIO.
#
# xdg-utils is a pile of shell and perl scripts that pull perl, file, gawk
# and jq into the closure. Electron only ever runs:
#
#   xdg-open URL|FILE                                     shell.openExternal, showItemInFolder
#   xdg-email mailto:...                                  shell.openExternal on mailto:
#   xdg-settings check default-url-scheme-handler P D     app.isDefaultProtocolClient
#   xdg-mime default D x-scheme-handler/P                 app.setAsDefaultProtocolClient
#   xdg-mime query default x-scheme-handler/P             app.getApplicationNameForProtocol
#
# and GIO, which gtk3 already brings, answers all of them from the same
# mimeapps.list files. The wrapper appends these to PATH, so a real
# xdg-utils on the system still wins.
{
  lib,
  runCommand,
  runtimeShell,
  glib,
}:

let
  gio = lib.getExe' glib "gio";

  # `gio mime TYPE` prints `Default application for “TYPE”: NAME.desktop`
  # when there is one, and something else entirely when there is not.
  queryDefault = ''
    query_default() {
      local line
      while IFS= read -r line; do
        case "$line" in
          "Default application for"*) printf '%s\n' "''${line##*: }"; return 0 ;;
        esac
      done < <(${gio} mime "$1" 2>/dev/null)
      return 1
    }
  '';

  scripts = {
    xdg-open = ''
      exec ${gio} open "$@"
    '';

    xdg-email = ''
      exec ${gio} open "$@"
    '';

    xdg-settings = ''
      ${queryDefault}
      case "$1 $2" in
        "check default-url-scheme-handler")
          if [ "$(query_default "x-scheme-handler/$3")" = "$4" ]; then
            echo yes
          else
            echo no
          fi
          ;;
        "get default-url-scheme-handler")
          query_default "x-scheme-handler/$3"
          ;;
        "set default-url-scheme-handler")
          exec ${gio} mime "x-scheme-handler/$3" "$4" >/dev/null
          ;;
        *)
          echo "xdg-settings: only default-url-scheme-handler is supported" >&2
          exit 3
          ;;
      esac
    '';

    xdg-mime = ''
      ${queryDefault}
      case "$1 $2" in
        "query default")
          query_default "$3"
          ;;
        "default "*)
          app="$2"
          shift 2
          for type in "$@"; do
            ${gio} mime "$type" "$app" >/dev/null || exit 4
          done
          ;;
        *)
          echo "xdg-mime: only 'query default' and 'default' are supported" >&2
          exit 3
          ;;
      esac
    '';
  };
in
runCommand "chatgpt-desktop-xdg-shims" { } (
  ''
    mkdir -p $out/bin
  ''
  + lib.concatStrings (
    lib.mapAttrsToList (name: body: ''
      cat >$out/bin/${name} <<'EOF'
      #!${runtimeShell}
      ${body}
      EOF
      chmod +x $out/bin/${name}
    '') scripts
  )
)
