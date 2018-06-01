rec {
    mountSecrets = lib: secrets: lib.listToAttrs (map (n: lib.nameValuePair (getPath n) {
        hostPath = getPath n;
        isReadOnly = true;
    }) secrets);
    getPath = secret: "/etc/secrets/${secret}";
    getBash = secret: "$(cat ${getPath secret})";
}