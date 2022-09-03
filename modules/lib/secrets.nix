rec {
  mountSecrets = lib: secrets: lib.listToAttrs (map
    (n: lib.nameValuePair (getPath n) {
      hostPath = getPath n;
      isReadOnly = true;
    })
    secrets);
  getPath = secret: "/var/keys/${secret}";
  getBash = secret: "$(cat ${getPath secret})";
}
