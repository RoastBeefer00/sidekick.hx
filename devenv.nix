{ pkgs, lib, config, inputs, ... }:

{
  packages = with pkgs; [
    git
    vhs
    ttyd
  ];

  scripts = {
    record.exec = ''
      cd "$(git rev-parse --show-toplevel)/demo"
      vhs sidekick.tape
    '';
  };

  enterShell = ''
    echo "sidekick.hx — record  : render demo/sidekick.tape → demo/sidekick.gif"
    echo "             Note: hx (helix-steel) must be on PATH for VHS recordings."
    # ttyd's libwebsockets is loaded via dlopen at runtime; keep its lib dir on
    # LD_LIBRARY_PATH so VHS recordings don't fail.
    _LWS_LIB=$(ldd "$(which ttyd)" 2>/dev/null | grep libwebsockets | grep -oP '=> \K\S+' | xargs dirname 2>/dev/null)
    if [ -n "$_LWS_LIB" ]; then
      export LD_LIBRARY_PATH="$_LWS_LIB''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
    unset _LWS_LIB
  '';
}
