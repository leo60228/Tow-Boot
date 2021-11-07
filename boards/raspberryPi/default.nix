{ systems
, runCommandNoCC
, gptfdisk
, imageBuilder
, vboot_reference
, writeText
, xxd
, fetchFromGitHub
}:

let
  inherit (systems) aarch64;
  inherit (aarch64.nixpkgs)
    raspberrypi-armstubs
  ;

  # TODO: not needed once https://github.com/NixOS/nixpkgs/pull/144649 lands
  raspberrypifw = aarch64.nixpkgs.raspberrypifw.overrideAttrs (oldAttrs: rec {
    version = "2021-11-02";

    src = fetchFromGitHub {
      owner = "raspberrypi";
      repo = "firmware";
      rev = "27f12ea332fa4d94b963f8e0f6e48502684a5343";
      sha256 = "uJnWIzLGnixe0PckhW3ibnvcm5GVAfix0SHozvrjtdI=";
    };
  });

  build = args: aarch64.buildTowBoot ({
    variant = "noenv";
    meta.platforms = ["aarch64-linux"];
    installPhase = ''
      cp -v u-boot.bin $out/binaries/Tow-Boot.$variant.bin
    '';
    patches = [
      ./0001-configs-rpi-allow-for-bigger-kernels.patch
      ./0001-Tow-Boot-rpi-Increase-malloc-pool-up-to-64MiB-env.patch
      ./0001-rpi-Add-identifier-for-Pi-Zero-2-W.patch
    ];
    # The necessary implementation is not provided by U-Boot.
    withPoweroff = false;
    # The TTF-based console somehow crashes the Pi.
    withTTF = false;
  } // args);

  raspberryPi-3 = build {
    boardIdentifier = "raspberryPi-3";
    defconfig = "rpi_3_defconfig";
  };
  raspberryPi-4 = build {
    boardIdentifier = "raspberryPi-4";
    defconfig = "rpi_4_defconfig";
  };
  raspberryPi-02w = build {
    boardIdentifier = "raspberryPi-02w";
    defconfig = "rpi_arm64_defconfig"; # no device tree in U-Boot/mainline yet
  };

  config = writeText "config.txt" ''
    [pi3]
    kernel=Tow-Boot.noenv.rpi3.bin

    [pi4]
    kernel=Tow-Boot.noenv.rpi4.bin
    enable_gic=1
    armstub=armstub8-gic.bin
    disable_overscan=1

    [pi02]
    kernel=Tow-Boot.noenv.rpi02w.bin

    [all]
    arm_64bit=1
    enable_uart=1
    avoid_warnings=1
  '';

  baseImage' = extraPartitions: imageBuilder.diskImage.makeGPT {
    name = "disk-image";
    diskID = "01234567";

    partitions = [
      firmwarePartition
    ] ++ extraPartitions;

    postBuild = ''
      (
      echo "Making hybrid MBR"
      PS4=" $ "
      PATH="${xxd}/bin/:${vboot_reference}/bin/:${gptfdisk}/bin/:$PATH"
      set -x
      sgdisk --hybrid=1:EE $img
      # Change the partition type to 0x0c; gptfdisk will default to 0x83 here.
      echo '000001c2: 0c' | xxd -r - $img
      sgdisk --print-mbr $img
      cgpt show -v $img
      )
    '';
  };

  inherit (imageBuilder.firmwarePartition { firmwareFile = null; partitionOffset = 0; partitionSize = 0; })
    partitionUUID
    partitionType
  ;

  # The build, since it includes misc. files from the Raspberry Pi Foundation
  # can get quite bigger, compared to other boards.
  firmwareMaxSize = imageBuilder.size.MiB 32;

  firmwarePartition = imageBuilder.fileSystem.makeFAT32 {
    size = firmwareMaxSize;
    partitionID = "0000000000000000";
    name = "TOW-BOOT-FIRM";
    offset = imageBuilder.size.MiB 1;
    inherit partitionUUID partitionType;
    populateCommands = ''
      cp -v ${config} config.txt
      cp -v ${raspberryPi-3}/binaries/Tow-Boot.noenv.bin Tow-Boot.noenv.rpi3.bin
      cp -v ${raspberryPi-4}/binaries/Tow-Boot.noenv.bin Tow-Boot.noenv.rpi4.bin
      cp -v ${raspberryPi-02w}/binaries/Tow-Boot.noenv.bin Tow-Boot.noenv.rpi02w.bin
      cp -v ${raspberrypi-armstubs}/armstub8-gic.bin armstub8-gic.bin
      (
        target="$PWD"
        cd ${raspberrypifw}/share/raspberrypi/boot
        cp -v bcm2711-rpi-4-b.dtb bcm2710-rpi-zero-2.dtb "$target/"
        cp -v bootcode.bin fixup*.dat start*.elf "$target/"
      )
    '';
  };

  baseImage = baseImage' [];
in
{
  #
  # Raspberry Pi
  # -------------
  #
  raspberryPi-aarch64 = runCommandNoCC "tow-boot-raspberryPi-aarch64-${raspberryPi-3.version}" {} ''
    mkdir -p $out/binaries
    mkdir -p $out/config

    (cd $out
      cp -rv ${raspberryPi-3.patchset} tow-boot-rpi3-patches
      cp -v ${raspberryPi-3}/binaries/Tow-Boot.noenv.bin $out/binaries/Tow-Boot.noenv.rpi3.bin
      cp -v ${raspberryPi-3}/config/noenv.config config/noenv.rpi3.config

      cp -rv ${raspberryPi-4.patchset} tow-boot-rpi4-patches
      cp -v ${raspberryPi-4}/binaries/Tow-Boot.noenv.bin $out/binaries/Tow-Boot.noenv.rpi4.bin
      cp -v ${raspberryPi-4}/config/noenv.config config/noenv.rpi4.config

      cp -rv ${raspberryPi-02w.patchset} tow-boot-rpi02w-patches
      cp -v ${raspberryPi-02w}/binaries/Tow-Boot.noenv.bin $out/binaries/Tow-Boot.noenv.rpi02w.bin
      cp -v ${raspberryPi-02w}/config/noenv.config config/noenv.rpi02w.config

      cp -v ${baseImage}/*.img $out/shared.disk-image.img
    )
  '';
}
