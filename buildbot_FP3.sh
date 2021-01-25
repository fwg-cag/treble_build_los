#!/bin/bash
# You may want to set, e.g. NPROC=2 and _JAVA_OPTIONS=-Xmx3061500416 to avoid java running out of heap with limited RAM
# Set OTA_DEVICE to get the right pre-device into the OTA zip file
# Set OTA_URL in case you want to follow https://forum.xda-developers.com/chef-central/android/guide-include-ota-updating-lineageos-t3944648
# https://android.googlesource.com/platform/bootable/recovery/+/master/updater_sample/res/raw/sample.json

echo ""
echo "LineageOS 17.x FP3 Buildbot"

CUSTOM_PACKAGES="GmsCore GsfProxy FakeStore MozillaNlpBackend NominatimNlpBackend com.google.android.maps.jar FDroid FDroidPrivilegedExtension AuroraServices"
START=`date +%s`
BUILD_DATE="$(date +%Y%m%d)"
BL=$PWD/treble_build_los
if [ -e $NPROC ]; then
    NPROC=`nproc --all`
fi

# Sync & patch only after 12h have passed
if [ `stat -c %Y .repo/.repo_fetchtimes.json` -lt $(expr `date +%s` - 43200) ]; then
  echo "ATTENTION: this script syncs repo"
  echo "Executing in 5 seconds - CTRL-C to exit"
  echo ""
  sleep 5

  echo "Remove previous changes of device/fairphone/FP3, vendor/lineage, frameworks/base and prebuilts/prebuiltapks (if they exist)"
  for path in "device/fairphone/FP3" "vendor/lineage" "frameworks/base" "prebuilts/prebuiltapks"; do
    (cd "$path" && git reset -q --hard && git clean -q -fd && git am --abort 2>/dev/null)
  done

  echo "Preparing local manifest"
  mkdir -p .repo/local_manifests
  cp $BL/manifest_FP3.xml .repo/local_manifests/manifest.xml
  echo ""

  echo "Syncing repos"
  repo sync -c --force-sync --no-clone-bundle --no-tags -j$NPROC
  # || touch --date="last week" .repo/.repo_fetchtimes.json; exit 1 GD todo
  echo ""

  echo "Preparing build environment"
  source build/envsetup.sh &> /dev/null
  breakfast FP3
  echo ""

##  echo "Reverting LOS FOD implementation"
##  cd frameworks/base
##  git am $BL/patches/0001-Squashed-revert-of-LOS-FOD-implementation.patch
##  cd ../..
##  cd frameworks/native
##  git am $BL/patches/0001-Revert-surfaceflinger-Add-support-for-extension-lib.patch
##  cd ../..
##  cd vendor/lineage
##  git revert 612c5a846ea5aed339fe1275c119ee111faae78c --no-edit # soong: Add flag for fod extension
##  cd ../..
##  echo ""

  echo "Applying universal patches"
  cd frameworks/base
##  git am $BL/patches/0001-UI-Revive-navbar-layout-tuning-via-sysui_nav_bar-tun.patch
  # FAKE_SIGNATURE permission can be obtained only by privileged system apps
  # git am $BL/patches/0001-core-Add-support-for-MicroG.patch
  TMPF=$(mktemp)
  sed 's/android:protectionLevel="dangerous"/android:protectionLevel="signature|privileged"/' $BL/patches/0001-core-Add-support-for-MicroG.patch > $TMPF
  git am $TMPF
  rm -f $TMPF
  cd ../..
##  cd lineage-sdk
##  git am $BL/patches/0001-sdk-Invert-per-app-stretch-to-fullscreen.patch
##  cd ..
##  cd packages/apps/LineageParts
##  git am $BL/patches/0001-LineageParts-Invert-per-app-stretch-to-fullscreen.patch
##  cd ../../..
# Commented out for security resons
# https://source.android.com/devices/tech/config/perms-whitelist
#  cd vendor/lineage
#  git am $BL/patches/0001-vendor_lineage-Log-privapp-permissions-whitelist-vio.patch
#  cd ../..
  echo ""

  echo "Adding microg"
  mkdir -p "vendor/lineage/overlay/microg/"
  sed -i "1s;^;PRODUCT_PACKAGE_OVERLAYS := vendor/lineage/overlay/microg\n;" "vendor/lineage/config/common.mk"
  # Override device-specific settings for the location providers
  mkdir -p "vendor/lineage/overlay/microg/frameworks/base/core/res/res/values/"
  cp $BL/patches/frameworks_base_config.xml "vendor/lineage/overlay/microg/frameworks/base/core/res/res/values/config.xml"

  # Set a custom updater URI if a OTA URL is provided
  if ! [ -z "$OTA_URL" ]; then
    echo "Set custom updater URI to $OTA"
    updater_url_overlay_dir="vendor/lineage/overlay/microg/packages/apps/Updater/res/values/"
    mkdir -p "$updater_url_overlay_dir"

    if [ -n "$(grep updater_server_url packages/apps/Updater/res/values/strings.xml)" ]; then
      # "New" updater configuration: full URL (with placeholders {device}, {type} and {incr})
#      sed "s|{name}|updater_server_url|g; s|{url}|$OTA_URL/v1/{device}/{type}/{incr}|g" $BL/patches/packages_updater_strings.xml > "$updater_url_overlay_dir/strings.xml"
      sed "s|{name}|updater_server_url|g; s|{url}|$OTA_URL|g" $BL/patches/packages_updater_strings.xml > "$updater_url_overlay_dir/strings.xml"
    elif [ -n "$(grep conf_update_server_url_def packages/apps/Updater/res/values/strings.xml)" ]; then
      # "Old" updater configuration: just the URL
      sed "s|{name}|conf_update_server_url_def|g; s|{url}|$OTA_URL|g" $BL/patches/packages_updater_strings.xml > "$updater_url_overlay_dir/strings.xml"
    else
      echo ">> [$(date)] ERROR: no known Updater URL property found"
      exit 1
    fi
  fi
  # Add custom packages to be installed
  if ! [ -z "$CUSTOM_PACKAGES" ]; then
    echo "Adding custom packages ($CUSTOM_PACKAGES)"
    sed -i "1s;^;PRODUCT_PACKAGES += $CUSTOM_PACKAGES\n\n;" "vendor/lineage/config/common.mk"
  fi
  # Sign if user-keys dir is present,
  # e.g. mkdir user-keys && cd user-keys && ln -s ../build/make/target/product/security/* && ln -s ~/android-certs/* .; cd ..
  # https://source.android.com/devices/tech/ota/sign_builds
  if [ -d user-keys ]; then
    sed -i "1s;^;PRODUCT_DEFAULT_DEV_CERTIFICATE := user-keys/releasekey\nPRODUCT_OTA_PUBLIC_KEYS := user-keys/releasekey\n\n;" "vendor/lineage/config/common.mk"
  fi
  unzip -o $BL/AuroraServices.zip
  if [ -f ./user-scripts/before.sh ]; then
    echo "Running before.sh"
    ./user-scripts/before.sh
  fi
  
  echo "CHECK PATCH STATUS NOW!"
  sleep 5
  echo ""
fi

echo "Setting up build environment"
source build/envsetup.sh &> /dev/null
echo ""

export WITHOUT_CHECK_API=true
# Commented out for security resons
#export WITH_SU=true
mkdir -p ~/build-output/

buildVariant() {
        breakfast ${1} || exit 1
        lunch lineage_${1}-userdebug || exit 1
	make installclean || exit 1
	mka bacon -j$NPROC || exit 1

	BUILD=lineage-17.1-$BUILD_DATE-UNOFFICIAL-${1}
	if ! [ -z "$OTA_URL" ] && ! [ -z "$OTA_DEVICE" ]; then
	  # Generate .json file
	  JSON_NAME=$(grep ro.build.display.id $OUT/obj/PACKAGING/target_files_intermediates/*${1}-target_files-*/SYSTEM/build.prop | sed -e "s/ /\//g" | awk -F= '{print $2}')
	  # Note: Testing to install the payload.bin on the device can be done via 
	  # update_engine_client --payload=file:///data/ota_package/payload.bin --update --follow --headers="FILE_HASH=(...)"
	  mv -f $OUT/$BUILD.zip ~/build-output/ || exit 1
          (cd ~/build-output; sha256sum "$BUILD.zip" > "$BUILD.zip.sha256sum") || exit 1
	  JSON_URL="$(echo $OTA_URL | sed -e "s/\(.*\)\/.*$/\1/")/$BUILD.zip"
	  cat <<EOT > ~/build-output/$BUILD.zip.json
{
  "response": [
    {
      "datetime": $(cat out/build_date.txt),
      "filename": "$BUILD.zip",
      "id": "$JSON_NAME",
      "romtype": "unofficial",
      "size": $(du -bs ~/build-output/$BUILD.zip | awk '{print $1}'),
      "url": "$JSON_URL",
      "version": "17.1"
    }
  ]
}
EOT
	fi
} # of buildVariant()

buildVariant FP3

END=`date +%s`
ELAPSEDM=$(($(($END-$START))/60))
ELAPSEDS=$(($(($END-$START))-$ELAPSEDM*60))
echo "Buildbot completed in $ELAPSEDM minutes and $ELAPSEDS seconds"
echo ""
(cd ~/build-output && ls | grep "lineage-17.1-$BUILD_DATE-*")
