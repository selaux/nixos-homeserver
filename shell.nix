with import <nixpkgs> {};
let
    nixpkgsPath = fetchFromGitHub {
        owner = "NixOS";
        repo = "nixpkgs-channels";
        # Tracking NixOS 18.03
        rev = "06c576b0525da85f2de86b3c13bb796d6a0c20f6";
        sha256 = "01cra89drfjf3yhii5na0j5ivap2wcs0h8i0xcxrjs946nk4pp5j";
    };
    nixpkgs = import nixpkgsPath {};
in
with nixpkgs;
{
    testEnv = stdenv.mkDerivation {
        name = "nixops-homeserver-test-env";
        buildInputs = [ nixops git-crypt ];
        shellHook = ''
            export NIX_PATH=nixpkgs=${nixpkgsPath}:.

            export NIXOPS_DEPLOYMENT=hs-test
            export NIXOPS_STATE=state/test.state.nixops

            alias createDeployment='nixops create -d hs-test ./networks/homeserver.nix ./environments/test.nix'
            alias generateSecrets='${python3}/bin/python scripts/generate_secrets.py'
            alias deploySecrets='nixops scp --to homeserver ./secrets/. /etc/secrets'
            alias bootstrap='generateSecrets && createDeployment && nixops deploy && nixops ssh-for-each "mount -o remount,rw /nix/store && chown -R root:root /nix/store" && deploySecrets && nixops deploy --force-reboot'

            git-crypt unlock
        '';
    };
}
