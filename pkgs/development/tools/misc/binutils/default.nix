{ stdenv, lib, buildPackages
, fetchFromGitHub, fetchurl, zlib, autoreconfHook, gettext
# Enabling all targets increases output size to a multiple.
, withAllTargets ? false, libbfd, libopcodes
, enableShared ? !stdenv.hostPlatform.isStatic
, noSysDirs
, gold ? true
, bison ? null
, flex
, texinfo
, perl
}:

# Note: this package is used for bootstrapping fetchurl, and thus
# cannot use fetchpatch! All mutable patches (generated by GitHub or
# cgit) that are needed here should be included directly in Nixpkgs as
# files.

let
  reuseLibs = enableShared && withAllTargets;

  version = "2.35.1";
  basename = "binutils";
  # The targetPrefix prepended to binary names to allow multiple binuntils on the
  # PATH to both be usable.
  targetPrefix = lib.optionalString (stdenv.targetPlatform != stdenv.hostPlatform)
                  "${stdenv.targetPlatform.config}-";
  vc4-binutils-src = fetchFromGitHub {
    owner = "itszor";
    repo = "binutils-vc4";
    rev = "708acc851880dbeda1dd18aca4fd0a95b2573b36";
    sha256 = "1kdrz6fki55lm15rwwamn74fnqpy0zlafsida2zymk76n3656c63";
  };
  # HACK to ensure that we preserve source from bootstrap binutils to not rebuild LLVM
  normal-src = stdenv.__bootPackages.binutils-unwrapped.src or (fetchurl {
    url = "mirror://gnu/binutils/${basename}-${version}.tar.bz2";
    sha256 = "sha256-Mg56HQ9G/Nn0E/EEbiFsviO7K85t62xqYzBEJeSLGUI=";
  });
in

stdenv.mkDerivation {
  pname = targetPrefix + basename;
  inherit version;

  src = if stdenv.targetPlatform.isVc4 then vc4-binutils-src else normal-src;

  patches = [
    # Make binutils output deterministic by default.
    ./deterministic.patch

    # Help bfd choose between elf32-littlearm, elf32-littlearm-symbian, and
    # elf32-littlearm-vxworks in favor of the first.
    # https://github.com/NixOS/nixpkgs/pull/30484#issuecomment-345472766
    ./disambiguate-arm-targets.patch

    # For some reason bfd ld doesn't search DT_RPATH when cross-compiling. It's
    # not clear why this behavior was decided upon but it has the unfortunate
    # consequence that the linker will fail to find transitive dependencies of
    # shared objects when cross-compiling. Consequently, we are forced to
    # override this behavior, forcing ld to search DT_RPATH even when
    # cross-compiling.
    ./always-search-rpath.patch

    ./CVE-2020-35448.patch
  ] ++ lib.optional stdenv.targetPlatform.isiOS ./support-ios.patch
    ++ # This patch was suggested by Nick Clifton to fix
       # https://sourceware.org/bugzilla/show_bug.cgi?id=16177
       # It can be removed when that 7-year-old bug is closed.
       # This binutils bug causes GHC to emit broken binaries on armv7, and
       # indeed GHC will refuse to compile with a binutils suffering from it. See
       # this comment for more information:
       # https://gitlab.haskell.org/ghc/ghc/issues/4210#note_78333
       lib.optional (stdenv.targetPlatform.isAarch32 && stdenv.hostPlatform.system != stdenv.targetPlatform.system) ./R_ARM_COPY.patch;

  outputs = [ "out" "info" "man" ];

  depsBuildBuild = [ buildPackages.stdenv.cc ];
  nativeBuildInputs = [
    bison
    perl
    texinfo
  ] ++ (lib.optionals stdenv.targetPlatform.isiOS [
    autoreconfHook
  ]) ++ lib.optionals stdenv.targetPlatform.isVc4 [ flex ];
  buildInputs = [ zlib gettext ];

  inherit noSysDirs;

  preConfigure = ''
    # Clear the default library search path.
    if test "$noSysDirs" = "1"; then
        echo 'NATIVE_LIB_DIRS=' >> ld/configure.tgt
    fi

    # Use symlinks instead of hard links to save space ("strip" in the
    # fixup phase strips each hard link separately).
    for i in binutils/Makefile.in gas/Makefile.in ld/Makefile.in gold/Makefile.in; do
        sed -i "$i" -e 's|ln |ln -s |'
    done
  '';

  # As binutils takes part in the stdenv building, we don't want references
  # to the bootstrap-tools libgcc (as uses to happen on arm/mips)
  NIX_CFLAGS_COMPILE = if stdenv.hostPlatform.isDarwin
    then "-Wno-string-plus-int -Wno-deprecated-declarations"
    else "-static-libgcc";

  hardeningDisable = [ "format" "pie" ];

  configurePlatforms = [ "build" "host" "target" ];

  configureFlags =
    (if enableShared then [ "--enable-shared" "--disable-static" ]
                     else [ "--disable-shared" "--enable-static" ])
  ++ lib.optional withAllTargets "--enable-targets=all"
  ++ [
    "--enable-64-bit-bfd"
    "--with-system-zlib"

    "--enable-deterministic-archives"
    "--disable-werror"
    "--enable-fix-loongson2f-nop"

    # Turn on --enable-new-dtags by default to make the linker set
    # RUNPATH instead of RPATH on binaries.  This is important because
    # RUNPATH can be overriden using LD_LIBRARY_PATH at runtime.
    "--enable-new-dtags"

    # force target prefix. Some versions of binutils will make it empty
    # if `--host` and `--target` are too close, even if Nixpkgs thinks
    # the platforms are different (e.g. because not all the info makes
    # the `config`). Other versions of binutils will always prefix if
    # `--target` is passed, even if `--host` and `--target` are the same.
    # The easiest thing for us to do is not leave it to chance, and force
    # the program prefix to be what we want it to be.
    "--program-prefix=${targetPrefix}"
  ] ++ lib.optionals gold [
    "--enable-gold"
    "--enable-plugins"
  ];

  doCheck = false; # fails

  postFixup = lib.optionalString reuseLibs ''
    rm "$out"/lib/lib{bfd,opcodes}-${version}.so
    ln -s '${lib.getLib libbfd}/lib/libbfd-${version}.so' "$out/lib/"
    ln -s '${lib.getLib libopcodes}/lib/libopcodes-${version}.so' "$out/lib/"
  '';

  # else fails with "./sanity.sh: line 36: $out/bin/size: not found"
  doInstallCheck = stdenv.buildPlatform == stdenv.hostPlatform && stdenv.hostPlatform == stdenv.targetPlatform;

  enableParallelBuilding = true;

  passthru = {
    inherit targetPrefix;
    isGNU = true;
  };

  meta = with lib; {
    description = "Tools for manipulating binaries (linker, assembler, etc.)";
    longDescription = ''
      The GNU Binutils are a collection of binary tools.  The main
      ones are `ld' (the GNU linker) and `as' (the GNU assembler).
      They also include the BFD (Binary File Descriptor) library,
      `gprof', `nm', `strip', etc.
    '';
    homepage = "https://www.gnu.org/software/binutils/";
    license = licenses.gpl3Plus;
    maintainers = with maintainers; [ ericson2314 ];
    platforms = platforms.unix;

    /* Give binutils a lower priority than gcc-wrapper to prevent a
       collision due to the ld/as wrappers/symlinks in the latter. */
    priority = 10;
  };
}
