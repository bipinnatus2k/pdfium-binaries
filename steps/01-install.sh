#!/bin/bash -eux

PATH_FILE=${GITHUB_PATH:-$PWD/.path}
TARGET_OS=${PDFium_TARGET_OS:?}
TARGET_ENVIRONMENT=${PDFium_TARGET_ENVIRONMENT:-}
TARGET_CPU=${PDFium_TARGET_CPU:?}
CURRENT_CPU=${PDFium_CURRENT_CPU:-x64}
MUSL_URL=${MUSL_URL:-https://musl.cc}
ENABLE_V8=${PDFium_ENABLE_V8:-false}
INPUT_CACHE=${INPUT_CACHE:-false}
INPUT_WAS_CACHED=${INPUT_WAS_CACHED:-false}

DepotTools_URL='https://chromium.googlesource.com/chromium/tools/depot_tools.git'
DepotTools_DIR="$PWD/depot_tools"
WindowsSDK_DIR="/c/Program Files (x86)/Windows Kits/10/bin/10.0.19041.0"

# Download depot_tools if not exists in this location
if [ ! -d "$DepotTools_DIR" ]; then
  git clone "$DepotTools_URL" "$DepotTools_DIR"
fi

echo "$DepotTools_DIR" >> "$PATH_FILE"

case "$TARGET_OS" in
  android)
    sudo apt-get update
    sudo apt-get install -y unzip

    # pdfium installs its version of the NDK, but we need one for compiling the example
    ANDROID_NDK_VERSION="r25c"
    ANDROID_NDK_FOLDER="android-ndk-$ANDROID_NDK_VERSION"
    ANDROID_NDK_ZIP="android-ndk-$ANDROID_NDK_VERSION-linux.zip"
    if [ ! -d "$ANDROID_NDK_FOLDER" ];
    then
      [ -f "$ANDROID_NDK_ZIP" ] || curl -Os "https://dl.google.com/android/repository/$ANDROID_NDK_ZIP"
      unzip -o -q "$ANDROID_NDK_ZIP"
      rm -f "$ANDROID_NDK_ZIP"
    fi
    echo "$PWD/$ANDROID_NDK_FOLDER/toolchains/llvm/prebuilt/linux-x86_64/bin" >> "$PATH_FILE"
    ;;

  linux)
    sudo apt-get update
    sudo apt-get install -y cmake pkg-config

    if [ "$TARGET_ENVIRONMENT" == "musl" ]; then

      case "$TARGET_CPU" in
        x86)
          MUSL_VERSION="i686-linux-musl-cross"
          PACKAGES="g++ g++-multilib"
          ;;

        x64)
          MUSL_VERSION="x86_64-linux-musl-cross"
          PACKAGES="g++"
          ;;

        arm)
          MUSL_VERSION="arm-linux-musleabihf-cross"
          PACKAGES="g++"
          ;;

        arm64)
          MUSL_VERSION="aarch64-linux-musl-cross"
          PACKAGES="g++"
          ;;
      esac

      [ -d "$MUSL_VERSION" ] || curl -L "$MUSL_URL/$MUSL_VERSION.tgz" | tar xz
      echo "$PWD/$MUSL_VERSION/bin" >> "$PATH_FILE"

      sudo apt-get install -y $PACKAGES

    else

      case "$TARGET_CPU" in
        arm)
          sudo apt-get install -y libc6-i386 gcc-10-multilib g++-10-arm-linux-gnueabihf gcc-10-arm-linux-gnueabihf
          ;;

        arm64)
          sudo apt-get install -y libc6-i386 gcc-10-multilib g++-10-aarch64-linux-gnu gcc-10-aarch64-linux-gnu
          ;;

        x86)
          sudo apt-get install -y g++-multilib
          ;;

        x64)
          sudo apt-get install -y g++
          ;;
      esac

    fi
    ;;
  
  ohos)
    sudo apt-get update

    URL_BASE="https://repo.huaweicloud.com/openharmony/os"

    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
            OS_FILENAME="ohos-sdk-windows_linux-public.tar.gz"
            OS=linux
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        if [[ $(uname -m) == 'arm64' ]]; then
            OS_FILENAME="L2-SDK-MAC-M1-PUBLIC.tar.gz"
        else
            OS_FILENAME="ohos-sdk-mac-public.tar.gz"
        fi
      OS=mac
    elif [[ "$OSTYPE" == "cygwin" ]] || [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "win32" ]]; then
            OS_FILENAME="ohos-sdk-windows_linux-public.tar.gz"
            OS=windows
    else
            echo "Unknown OS type. The OHOS SDK is only available for Windows, Linux and macOS."
            exit 1
    fi

    WORK_DIR="${HOME}/setup-ohos-sdk"
    mkdir -p "${WORK_DIR}"
    cd "${WORK_DIR}"

    # Assumption: cwd contains the zipped components.
    # Outputs: API_VERSION
    function extract_sdk_components() {
        if [[ "${INPUT_COMPONENTS}" == "all" ]]; then
          COMPONENTS=(*.zip)
        else
          IFS=";" read -ra COMPONENTS <<< "${INPUT_COMPONENTS}"
          resolved_components=()
          for COMPONENT in "${COMPONENTS[@]}"
          do
            resolved_components+=("${COMPONENT}"-*.zip)
          done
          COMPONENTS=(${resolved_components[@]})
        fi

        for COMPONENT in "${COMPONENTS[@]}"
        do
            echo "Extracting component ${COMPONENT}"
            echo "::group::Unzipping archive"
            #shellcheck disable=SC2144
            if [[ -f "${COMPONENT}" ]]; then
              unzip -q "${COMPONENT}"
            else
              echo "Failed to find component ${COMPONENT}"
              ls -la
              exit 1
            fi
            echo "::endgroup::"
            # Removing everything after the first dash should give us the component dir
            component_dir=${COMPONENT%%-*}
            API_VERSION=$(jq -r '.apiVersion' < "${component_dir}/oh-uni-package.json")
            if [ "$INPUT_FIXUP_PATH" = "true" ]; then
                mkdir -p "${API_VERSION}"
                mv "${component_dir}" "${API_VERSION}/"
            fi
        done
        rm ./*.zip
    }

    function download_and_extract_sdk() {
        MIRROR_DOWNLOAD_SUCCESS=false
        if [[ "${INPUT_MIRROR}" == "true" || "${INPUT_MIRROR}" == "force" ]]; then
          RESOLVED_MIRROR_VERSION_TAG="v${INPUT_VERSION}"
          gh release download "${RESOLVED_MIRROR_VERSION_TAG}" --pattern "${OS_FILENAME}*" --repo openharmony-rs/ohos-sdk && MIRROR_DOWNLOAD_SUCCESS=true
          if [[ "${MIRROR_DOWNLOAD_SUCCESS}" == "true" ]]; then
            # The mirror may have split the archives due to the Github releases size limits.
            # First rename the sha256 file, so we don't glob it.
            mv "${OS_FILENAME}.sha256" "sha256.${OS_FILENAME}"
            # Now get all the .aa .ab etc. output of the split command for our filename
            shopt -s nullglob
            split_files=("${OS_FILENAME}".*)
            if [ ${#split_files[@]} -ne  0 ]; then
              cat "${split_files[@]}" > "${OS_FILENAME}"
              rm "${split_files[@]}"
            fi
            # Rename the shafile back again to the original name
            mv "sha256.${OS_FILENAME}" "${OS_FILENAME}.sha256"
          elif [[ "${INPUT_MIRROR}" == "force" ]]; then
            echo "Downloading from mirror failed, and mirror=force. Failing the job."
            echo "Note: mirror=force is for internal test purposes, and should not be selected by users."
            exit 1
          else
            echo "Failed to download SDK from mirror. Falling back to downloading from upstream."
          fi
        fi
        if [[ "${MIRROR_DOWNLOAD_SUCCESS}" != "true" ]]; then
          DOWNLOAD_URL="${URL_BASE}/${INPUT_VERSION}-Release/${OS_FILENAME}"
          echo "Downloading OHOS SDK from ${DOWNLOAD_URL}"
          curl --fail -L -O "${DOWNLOAD_URL}"
          curl --fail -L -O "${DOWNLOAD_URL}.sha256"
        fi

        if [[ "${OS}" == "mac" ]]; then
            echo "$(cat "${OS_FILENAME}".sha256)  ${OS_FILENAME}" | shasum -a 256 --check --status
            tar -xf "${OS_FILENAME}" --strip-components=3
        else
            echo "$(cat "${OS_FILENAME}".sha256) ${OS_FILENAME}" | sha256sum --check --status
            if [[ "${INPUT_VERSION}" == "5.0.0" || "${INPUT_VERSION}" == "5.0.1" ]]; then
              tar -xf "${OS_FILENAME}"
            else
              tar -xf "${OS_FILENAME}" --strip-components=1
            fi
        fi
        rm "${OS_FILENAME}" "${OS_FILENAME}.sha256"

        if [[ "${OS}" == "linux" ]]; then
            rm -rf windows
            rm -rf ohos
            cd linux
        elif [[ "${OS}" == "windows" ]]; then
            rm -rf linux
            rm -rf ohos
            cd windows
        else
            cd darwin
        fi
        OHOS_BASE_SDK_HOME="$PWD"
        extract_sdk_components
    }

    echo "sdk-path=$PWD" >> "${GITHUB_OUTPUT}"

    if [[ "${INPUT_CACHE}" != "true" || "${INPUT_WAS_CACHED}" != "true" ]]; then
        download_and_extract_sdk
    else
        if [[ "${OS}" == "linux" ]]; then
            cd linux
        elif [[ "${OS}" == "windows" ]]; then
            cd windows
        else
            cd darwin
        fi
        OHOS_BASE_SDK_HOME="$PWD"
    fi

    if [ "${INPUT_FIXUP_PATH}" = "true" ]; then
      # When we are restoring from cache we don't know the API version, so we glob for now.
      # In the future we should do something more robust, like copying `oh-uni-package.json` to the root.
      OHOS_NDK_HOME=$(cd "${OHOS_BASE_SDK_HOME}"/* && pwd)
      OHOS_SDK_NATIVE="${OHOS_NDK_HOME}"/native
    else
      OHOS_NDK_HOME="${OHOS_BASE_SDK_HOME}"
      OHOS_SDK_NATIVE="${OHOS_BASE_SDK_HOME}/native"
    fi

    cd "${OHOS_SDK_NATIVE}"
    SDK_VERSION="$(jq -r .version < oh-uni-package.json )"
    API_VERSION="$(jq -r .apiVersion < oh-uni-package.json )"
    echo "OHOS_BASE_SDK_HOME=${OHOS_BASE_SDK_HOME}" >> "$GITHUB_ENV"
    echo "ohos-base-sdk-home=${OHOS_BASE_SDK_HOME}" >> "$GITHUB_OUTPUT"
    echo "OHOS_NDK_HOME=${OHOS_NDK_HOME}" >> "$GITHUB_ENV"
    echo "OHOS_SDK_NATIVE=${OHOS_SDK_NATIVE}" >> "$GITHUB_ENV"
    echo "ohos_sdk_native=${OHOS_SDK_NATIVE}" >> "$GITHUB_OUTPUT"
    echo "sdk-version=${SDK_VERSION}" >> "$GITHUB_OUTPUT"
    echo "api-version=${API_VERSION}" >> "$GITHUB_OUTPUT"

    ;;

  win)
    echo "$WindowsSDK_DIR/$CURRENT_CPU" >> "$PATH_FILE"
    ;;

  ios)
    # Xcode 15.4 produces the following error when targeting ARM64 with V8:
    # undefined symbol: be_memory_inline_jit_restrict_rwx_to_rx_with_witness_impl
    sudo xcode-select -s "/Applications/Xcode_15.0.1.app"
    ;;

  emscripten)
    if [ "$ENABLE_V8" == "true" ]; then
      sudo apt-get update
      # We need to install the snapshot toolchain for x86
      sudo apt-get install -y g++-multilib
    fi
esac
