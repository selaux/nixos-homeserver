with import <nixpkgs> {};
let
    nixpkgsPath = fetchFromGitHub {
        owner = "NixOS";
        repo = "nixpkgs-channels";
        # Tracking NixOS Unstable
        rev = "4b649a99d8461c980e7028a693387dc48033c1f7";
        sha256 = "0iy2gllj457052wkp20baigb2bnal9nhyai0z9hvjr3x25ngck4y";
    };
    nixpkgs = import nixpkgsPath {};
in
with nixpkgs;
{
    testEnv = stdenv.mkDerivation {
        name = "nixops-homeserver-test-env";
        buildInputs = [ nixops openssh openssl ];
        shellHook = ''
            export NIX_PATH=nixpkgs=${nixpkgsPath}:.

            export NIXOPS_DEPLOYMENT=homeserver-test
            export NIXOPS_STATE=nixops/state/homeserver-test.state.nixops

            alias createDeployment='nixops create -d $NIXOPS_DEPLOYMENT ./nixops/test-network.nix ./nixops/test-libvirt.nix'
            alias generateSecrets='${python3}/bin/python scripts/generate_secrets.py'
            alias deploySecrets='nixops scp --to homeserver ./secrets/. /etc/secrets'
            alias bootstrap='generateSecrets && createDeployment && nixops deploy && nixops ssh-for-each "mount -o remount,rw /nix/store && chown -R root:root /nix/store" && deploySecrets && nixops deploy --force-reboot'
        '';
    };
}
