{
  homeserver = {
    deployment.targetEnv = "libvirtd";
    deployment.libvirtd.vcpu = 4;
    deployment.libvirtd.memorySize = 1024;
  };
}