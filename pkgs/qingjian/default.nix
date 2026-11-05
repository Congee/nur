{
  lib,
  stdenv,
  rustPlatform,
  fetchFromGitHub,
  fetchurl,
  imagemagick,
  libicns,
  oniguruma,
  # Linux
  cmake,
  pkg-config,
  python3,
  openssl,
  fcitx5,
  nlohmann_json,
  libxkbcommon,
  wayland,
  libx11,
  libxcursor,
  libxi,
  libxrandr,
  dejavu_fonts,
  noto-fonts-cjk-sans,
  noto-fonts-color-emoji,
}:

let
  # Product data release pinned by tools/release/data.lock at the source tag.
  dataTag = "data-v10";
  dataHash = "sha256-Ys8rQ+tJyGBlVEogCLISGwZcDTDkfBLQiTLIrDD1OrY=";

  inherit (stdenv.hostPlatform) isDarwin isLinux;
in
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "qingjian";
  version = "0.3.3";

  src = fetchFromGitHub {
    owner = "qingjian-team";
    repo = "qingjian";
    tag = "v${finalAttrs.version}";
    hash = "sha256-rsWvg/aAD8oIKQEh+4IFP7lNQBRiLGofHPEKUhXJtLc=";
  };

  data = fetchurl {
    url = "https://github.com/qingjian-team/qingjian/releases/download/${dataTag}/qingjian-data.tar.gz";
    hash = dataHash;
  };

  cargoHash = "sha256-czZijlOPaP9Kahq90dRkuRnkcwvXQbIaNpxPFMq2i/8=";

  nativeBuildInputs =
    lib.optionals isDarwin [
      imagemagick
      libicns
    ]
    ++ lib.optionals isLinux [
      cmake
      pkg-config
      python3
    ];

  # nixpkgs sets RUSTONIG_SYSTEM_LIBONIG, so onig_sys links the system library
  buildInputs = [
    oniguruma
  ]
  ++ lib.optionals isLinux [
    openssl
    fcitx5
    nlohmann_json
  ];

  # The fcitx5 addon is built by hand after cargo, not as the top-level project.
  dontUseCmakeConfigure = true;

  cargoBuildFlags = [
    "-p"
    (if isDarwin then "qingjian-macos" else "qingjian-linux-server")
    "-p"
    "qingjian-settings"
  ];

  env.QINGJIAN_BUILD = "nix · ${finalAttrs.version}";

  # The settings app loads fonts from a fixed list of FHS paths (no fontconfig),
  # and finds its resources beside the exe or under /usr/share/qingjian.
  postPatch = lib.optionalString isLinux ''
    substituteInPlace crates/bamboo-slip/src/fonts/linux.rs \
      --replace-fail '"/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",' \
        '"${dejavu_fonts}/share/fonts/truetype/DejaVuSans.ttf", "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",' \
      --replace-fail '"/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf",' \
        '"${dejavu_fonts}/share/fonts/truetype/DejaVuSans-Bold.ttf", "/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf",' \
      --replace-fail '"/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",' \
        '"${noto-fonts-cjk-sans}/share/fonts/opentype/noto-cjk/NotoSansCJK-VF.otf.ttc", "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",' \
      --replace-fail '"/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",' \
        '"${noto-fonts-color-emoji}/share/fonts/noto/NotoColorEmoji.ttf", "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",'
    substituteInPlace crates/qingjian-platform/src/resources.rs \
      --replace-fail 'const SYSTEM_ROOTS: [&str; 3] = [' "const SYSTEM_ROOTS: [&str; 4] = [ \"$out/share/qingjian/resources\","
  '';

  # Not postUnpack: the cargo vendor derivation inherits it but not `data`.
  # macOS bundles only data/generated; Linux also ships the sentence model.
  preBuild =
    if isDarwin then
      ''
        tar -xzf ${finalAttrs.data} data/generated
      ''
    else
      ''
        tar -xzf ${finalAttrs.data} --exclude='._*'
        # files.py checks the extracted data against the archive pinned in data.lock
        mkdir -p target/release-data
        ln -s ${finalAttrs.data} target/release-data/qingjian-data.tar.gz
      '';

  postBuild = lib.optionalString isLinux ''
    cmake -S apps/linux/fcitx5 -B build-fcitx5 \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DCMAKE_INSTALL_PREFIX=$out
    cmake --build build-fcitx5 --parallel $NIX_BUILD_CORES
  '';

  doCheck = false;

  installPhase =
    if isDarwin then
      ''
        runHook preInstall

        # Mirrors apps/macos/scripts/bundle.sh, minus PlistBuddy/sips/iconutil.
        bin=target/${stdenv.hostPlatform.rust.cargoShortTarget}/release
        app="$out/Library/Input Methods/Qingjian.app"
        res="$app/Contents/Resources"
        settings="$app/Contents/Applications/QingjianSettings.app"
        mkdir -p "$app/Contents/MacOS" "$res" "$settings/Contents/MacOS" "$settings/Contents/Resources" $out/bin

        install -m755 $bin/qingjian-macos "$app/Contents/MacOS/"
        install -m755 $bin/qingjian-settings "$settings/Contents/MacOS/"
        sed -e '/CFBundleShortVersionString/{n;s|>.*<|>${finalAttrs.version}<|;}' \
          apps/macos/Info.plist > "$app/Contents/Info.plist"
        sed -e '/CFBundleShortVersionString/{n;s|>.*<|>${finalAttrs.version}<|;}' \
          apps/settings/macos/Info.plist > "$settings/Contents/Info.plist"
        printf 'APPL????' > "$app/Contents/PkgInfo"

        cp -R apps/macos/resources/*.lproj "$res/"
        cp assets/sample/*.tsv assets/emoji/*.tsv assets/levels/levels-*.tsv "$res/"
        for scheme in assets/schemes/*/; do
          mkdir -p "$res/schemes/$(basename $scheme)"
          cp $scheme/scheme.toml $scheme/table.tsv "$res/schemes/$(basename $scheme)/"
        done
        cp data/generated/dict.qj data/generated/lm.qj data/generated/glossary-*.qj "$res/"
        mkdir -p "$res/dicts" "$res/codes"
        cp data/generated/dicts/*.qj "$res/dicts/"
        cp data/generated/codes/*.qj assets/stroke/LICENSE-CNS11643.txt "$res/codes/"
        for f in assets/lexicon/english.tsv data/generated/english.tsv; do
          if [ -f $f ]; then cp $f "$res/"; fi
        done
        cp assets/icon/menu.pdf "$res/qingjian-menu.pdf"

        for size in 16 32 128 256 512; do
          magick assets/icon/macos/app.png -resize ''${size}x$size icon_$size.png
        done
        png2icns "$res/Qingjian.icns" icon_{16,32,128,256,512}.png
        cp "$res/Qingjian.icns" "$settings/Contents/Resources/"

        # `qingjian-macos --register` enables the input source after linking the bundle.
        ln -s "$app/Contents/MacOS/qingjian-macos" $out/bin/qingjian-macos

        runHook postInstall
      ''
    else
      ''
        runHook preInstall

        # Mirrors apps/linux/scripts/install.sh + files.py, at a store prefix.
        bin=target/${stdenv.hostPlatform.rust.cargoShortTarget}/release
        install -Dm755 -t $out/bin $bin/qingjian-linux-server $bin/qingjian-settings
        # lib/fcitx5/qingjian.so and share/fcitx5/{addon,inputmethod}/qingjian.conf
        cmake --install build-fcitx5

        # The server looks for <exe>/../share/qingjian/resources
        python3 apps/linux/scripts/files.py resources $out/share/qingjian/resources --root "$PWD"

        mkdir -p $out/share/systemd/user $out/share/applications
        sed "s|@EXEC@|$out/bin/qingjian-linux-server|" apps/linux/scripts/qingjian-server.service.in \
          > $out/share/systemd/user/qingjian-server.service
        sed "s|^Exec=qingjian-settings$|Exec=$out/bin/qingjian-settings|" apps/settings/linux/qingjian-settings.desktop \
          > $out/share/applications/qingjian-settings.desktop
        for size in 16 22 24 32 48 64 128 256; do
          install -Dm644 assets/icon/linux/hicolor/''${size}x$size/apps/qingjian.png \
            $out/share/icons/hicolor/''${size}x$size/apps/qingjian.png
        done
        install -Dm644 -t $out/share/licenses/qingjian LICENSE assets/stroke/LICENSE-CNS11643.txt

        runHook postInstall
      '';

  # winit / softbuffer / arboard dlopen the windowing libraries.
  postFixup = lib.optionalString isLinux ''
    patchelf --add-rpath ${
      lib.makeLibraryPath [
        libxkbcommon
        wayland
        libx11
        libxcursor
        libxi
        libxrandr
      ]
    } $out/bin/qingjian-settings
  '';

  meta = {
    description = "Pinyin input method that shows a translation of each candidate in the language you are learning";
    longDescription = ''
      On macOS this is the input method bundle. On Linux it is the engine
      server (a systemd user service), the fcitx5 addon that talks to it,
      and the settings app.
    '';
    homepage = "https://qingjian.app";
    changelog = "https://github.com/qingjian-team/qingjian/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.gpl3Plus;
    maintainers = with lib.maintainers; [ congee ];
    mainProgram = if isDarwin then "qingjian-macos" else "qingjian-linux-server";
    platforms = [
      "aarch64-darwin"
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
})
